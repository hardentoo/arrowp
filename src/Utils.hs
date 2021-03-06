{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeFamilies        #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing -Wno-orphans #-}
module Utils
  ( S(..)
  , HSE.rebracket1
  , freeVars
  , freeVarss
  , definedVars
  , irrPat
  , trimPat
  , left, right
  , pair
  , pairP
  , same
  , times
  , app_exp
  , arr_exp
  , first_exp
  , loop_exp
  , returnA_exp
  , choice_op
  , compose_op
  , returnCmd
  , observeSt
  , (<$$>)
  , traverseAlt
  , traverseAlts
  )where

import           Control.Monad
import           Control.Monad.Trans.State
import           Data.Data
import           Data.Default
import           Data.Functor.Identity
import           Data.Generics.Uniplate.Data
import           Data.List
import           Data.Map                      (Map)
import           Data.Set                      (Set)
import qualified Data.Set                      as Set
import           Debug.Hoed.Pure               hiding (Module)
import           Debug.Hoed.Pure.TH
import           Language.Haskell.Exts
import qualified Language.Haskell.Exts.Util    as HSE
#ifdef DEBUG
import           Language.Haskell.Exts.Observe ()
#endif
import           NewCode
import           SrcLocs

freeVars
  :: ( Observable a
     , HSE.FreeVars a
     )
  => a -> Set (Name ())
freeVars = observe "freeVars" HSE.freeVars

freeVarss
  :: ( Observable a
     , HSE.AllVars a
     )
  => a -> Set (Name ())
freeVarss = observe "freeVarss" (HSE.free . HSE.allVars)

definedVars
  :: ( Observable a
     , HSE.AllVars a
     )
  => a -> Set (Name ())
definedVars = observe "definedVars" (HSE.bound . HSE.allVars)

-- | Are a tuple pattern and an expression tuple equal ?
same :: (Eq s, Observable(Exp s), Observable(Pat s)) => Pat s -> Exp s -> Bool
same = observe "same" same'

same' :: (Eq s, Observable(Exp s), Observable(Pat s)) => Pat s -> Exp s -> Bool
same' (PApp _ n1 []) (Con _ n2) = n1 == n2
same' (PVar l n1) (Var _ n2) = UnQual l n1 == n2
same' (PTuple _ Boxed []) y = same (PApp (ann y) (unit_con_name (ann y)) []) y
same' (PTuple _ Boxed [pv]) y = same pv y
same' y (Tuple _ Boxed []) = same y (unit_con(ann y))
same' y (Tuple _ Boxed [pv]) = same y pv
same' (PTuple _ boxed ps) (Tuple _ boxed' es) =
  length ps == length es && boxed == boxed' && and (zipWith same ps es)
same' (PAsPat _ n _) (Var _ (UnQual _ n')) = n == n'
same' (PAsPat _ _ p) e = same p e
same' (PParen _ p) e = same p e
same' p (Paren _ e) = same p e
same' _ _ = False

times :: Int -> (a -> a) -> a -> a
times n f x = iterate f x !! n

-- | Hide variables that don't satisfy a predicate
filterPat :: (Data a) => (Name a -> Bool) -> Pat a -> Pat a
filterPat pred = transform go where
  go p@(PVar l n)
    | pred n = p
    | otherwise = PWildCard l
  go (PAsPat _ n p)
    | not(pred n) = go p
  go x = x

-- | Hide variables from a pattern
hidePat :: Data a => Set (Name ()) -> Pat a -> Pat a
hidePat vs = filterPat (not . (`Set.member` vs) . void)

obs [d|
  trimPat :: Exp S -> Pat S -> Pat S
  trimPat vs = filterPat ((`Set.member` freeVars vs) . void)
    |]

pair :: Exp code -> Exp code -> Exp code
pair e1 e2 = Tuple (ann e1) Boxed [e1, e2]

pairP :: Pat S -> Pat S -> Pat S
pairP p1 p2 = PTuple (ann p1) Boxed [hidePat (definedVars p2) p1, p2]

left, right :: Default code => Exp code -> Exp code
left  x = App (ann x) left_exp  (Paren def x)
right x = App (ann x) right_exp (Paren def x)

returnCmd :: Default code => Exp code -> Exp code
returnCmd x = LeftArrApp (ann x) returnA_exp x

compose_op, choice_op :: Default s => QOp s
returnA_exp, arr_exp, first_exp :: Default s => Exp s
left_exp, right_exp, app_exp, loop_exp :: Default s => Exp s
unqualId :: Default s => String -> Exp s
unqualId   id = Var def $ UnQual def (Ident def id)
unqualOp :: Default s => String -> QOp s
unqualOp id = QVarOp def $ UnQual def (Symbol def id)
unqualCon :: Default s => String -> Exp s
unqualCon  id = Con def $ UnQual def (Symbol def id)
arr_exp       = unqualId "arr"
compose_op    = unqualOp ">>>"
first_exp     = unqualId "first"
returnA_exp   = unqualId "returnA"
choice_op     = unqualOp "|||"
left_exp      = unqualCon "Left"
right_exp     = unqualCon "Right"
app_exp       = unqualId "app"
loop_exp      = unqualId "loop"


-- | Irrefutable version of a pattern

irrPat :: Pat S -> Pat S
irrPat p@PVar{}       = p
irrPat (PParen l p)   = PParen l (irrPat p)
irrPat (PAsPat l n p) = PAsPat l n (irrPat p)
irrPat p@PWildCard{}  = p
irrPat p@PIrrPat{}    = p
irrPat p              = PIrrPat (ann p) p

-- | Observing functions for algorithmic debugging

observeSt
  :: (Observable a, Observable b, Observable c, Observable s)
  => String -> (a -> b -> State s c) -> a -> b -> State s c
observeSt name f a b = StateT $ \s -> Identity $ observe name f' a b s
  where
    f' a b = runState (f a b)

instance (Eq a, Show a) => Observable (Set a) where
  constrain = constrainBase
  observer = observeBase

instance (Eq a, Eq k, Show a, Show k) => Observable (Map k a) where
  constrain = constrainBase
  observer = observeBase

-- Override some AST instances for comprehension
instance {-# OVERLAPS #-} Observable (Exp Code) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (Exp S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (Name S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (QName S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable [Stmt S] where
  observer lit cxt =
    seq lit $ send (bracket $ intercalate ";" $ fmap prettyPrint lit) (return lit) cxt
instance {-# OVERLAPS #-} Observable (Stmt S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (Pat Code) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (Pat S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (QOp S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (Op S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (Rhs S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (Alt S) where
  observer = observePretty
instance {-# OVERLAPS #-} Observable (Set (Name S)) where
  constrain = constrainBase
  observer x cxt =
    seq x $ send (between "[" "]"$ intercalate "," $ prettyPrint <$> map void (Set.toList x)) (return x) cxt
instance {-# OVERLAPS #-} Observable (Set (Name ())) where
  constrain = constrainBase
  observer x cxt =
    seq x $ send (between "[" "]"$ intercalate "," $ prettyPrint <$> map void (Set.toList x)) (return x) cxt

observePretty lit cxt =
  seq lit $ send (between "<" ">" $ prettyPrint lit) (return lit) cxt

bracket :: [Char] -> [Char]
between open  close s = open ++ s ++ close
bracket = between "[" "]"

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) f = fmap (fmap f)

traverseAlt :: (Data s, Monad a) => (Exp s -> a(Exp s)) -> Alt s -> a(Alt s)
traverseAlt = descendBiM
traverseAlts :: (Data s, Monad a) => (Exp s -> a(Exp s)) -> [Alt s] -> a [Alt s]
traverseAlts = traverse.traverseAlt

