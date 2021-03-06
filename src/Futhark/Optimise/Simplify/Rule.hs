{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}
-- | This module defines the concept of a simplification rule for
-- bindings.  The intent is that you pass some context (such as symbol
-- table) and a binding, and is given back a sequence of bindings that
-- compute the same result, but are "better" in some sense.
--
-- These rewrite rules are "local", in that they do not maintain any
-- state or look at the program as a whole.  Compare this to the
-- fusion algorithm in @Futhark.Optimise.Fusion.Fusion@, which must be implemented
-- as its own pass.
module Futhark.Optimise.Simplify.Rule
       ( -- * The rule monad
         RuleM
       , cannotSimplify
       , liftMaybe

       -- * Rule definition
       , Rule(..)
       , SimplificationRule(..)
       , RuleGeneric
       , RuleBasicOp
       , RuleIf
       , RuleDoLoop

       -- * Top-down rules
       , TopDown
       , TopDownRule
       , TopDownRuleGeneric
       , TopDownRuleBasicOp
       , TopDownRuleIf
       , TopDownRuleDoLoop
       , TopDownRuleOp

       -- * Bottom-up rules
       , BottomUp
       , BottomUpRule
       , BottomUpRuleGeneric
       , BottomUpRuleBasicOp
       , BottomUpRuleIf
       , BottomUpRuleDoLoop
       , BottomUpRuleOp

       -- * Assembling rules
       , RuleBook
       , ruleBook

         -- * Applying rules
       , topDownSimplifyStm
       , bottomUpSimplifyStm
       ) where

import Control.Monad.State
import qualified Control.Monad.Fail as Fail
import Control.Monad.Except

import qualified Futhark.Analysis.SymbolTable as ST
import qualified Futhark.Analysis.UsageTable as UT
import Futhark.IR
import Futhark.Binder

data RuleError = CannotSimplify
               | OtherError String

-- | The monad in which simplification rules are evaluated.
newtype RuleM lore a = RuleM (BinderT lore (StateT VNameSource (Except RuleError)) a)
  deriving (Functor, Applicative, Monad,
            MonadFreshNames, HasScope lore, LocalScope lore,
            MonadError RuleError)

instance Fail.MonadFail (RuleM lore) where
  fail = throwError . OtherError

instance (ASTLore lore, BinderOps lore) => MonadBinder (RuleM lore) where
  type Lore (RuleM lore) = lore
  mkExpDecM pat e = RuleM $ mkExpDecM pat e
  mkBodyM bnds res = RuleM $ mkBodyM bnds res
  mkLetNamesM pat e = RuleM $ mkLetNamesM pat e

  addStms = RuleM . addStms
  collectStms (RuleM m) = RuleM $ collectStms m

-- | Execute a 'RuleM' action.  If succesful, returns the result and a
-- list of new bindings.  Even if the action fail, there may still be
-- a monadic effect - particularly, the name source may have been
-- modified.
simplify :: Scope lore -> VNameSource -> Rule lore
         -> Maybe (Stms lore, VNameSource)
simplify _ _ Skip = Nothing
simplify scope src (Simplify (RuleM m)) =
  case runExcept $ runStateT (runBinderT m scope) src of
    Left CannotSimplify -> Nothing
    Left (OtherError err) -> error $ "simplify: " ++ err
    Right (((), x), src') -> Just (x, src')

cannotSimplify :: RuleM lore a
cannotSimplify = throwError CannotSimplify

liftMaybe :: Maybe a -> RuleM lore a
liftMaybe Nothing = cannotSimplify
liftMaybe (Just x) = return x

-- | An efficient way of encoding whether a simplification rule should even be attempted.
data Rule lore = Simplify (RuleM lore ()) -- ^ Give it a shot.
               | Skip -- ^ Don't bother.

type RuleGeneric lore a = a -> Stm lore -> Rule lore
type RuleBasicOp lore a = (a -> Pattern lore -> StmAux (ExpDec lore) ->
                           BasicOp -> Rule lore)
type RuleIf lore a = a -> Pattern lore -> StmAux (ExpDec lore) ->
                     (SubExp, BodyT lore, BodyT lore,
                      IfDec (BranchType lore)) ->
                     Rule lore
type RuleDoLoop lore a = a -> Pattern lore -> StmAux (ExpDec lore) ->
                         ([(FParam lore, SubExp)], [(FParam lore, SubExp)],
                          LoopForm lore, BodyT lore) ->
                         Rule lore
type RuleOp lore a = a -> Pattern lore -> StmAux (ExpDec lore) ->
                     Op lore -> Rule lore

-- | A simplification rule takes some argument and a statement, and
-- tries to simplify the statement.
data SimplificationRule lore a = RuleGeneric (RuleGeneric lore a)
                               | RuleBasicOp (RuleBasicOp lore a)
                               | RuleIf (RuleIf lore a)
                               | RuleDoLoop (RuleDoLoop lore a)
                               | RuleOp (RuleOp lore a)

-- | A collection of rules grouped by which forms of statements they
-- may apply to.
data Rules lore a = Rules { rulesAny :: [SimplificationRule lore a]
                       , rulesBasicOp :: [SimplificationRule lore a]
                       , rulesIf :: [SimplificationRule lore a]
                       , rulesDoLoop :: [SimplificationRule lore a]
                       , rulesOp :: [SimplificationRule lore a]
                       }

instance Semigroup (Rules lore a) where
  Rules as1 bs1 cs1 ds1 es1 <> Rules as2 bs2 cs2 ds2 es2 =
    Rules (as1<>as2) (bs1<>bs2) (cs1<>cs2) (ds1<>ds2) (es1<>es2)

instance Monoid (Rules lore a) where
  mempty = Rules mempty mempty mempty mempty mempty

-- | Context for a rule applied during top-down traversal of the
-- program.  Takes a symbol table as argument.
type TopDown lore = ST.SymbolTable lore

type TopDownRuleGeneric lore = RuleGeneric lore (TopDown lore)
type TopDownRuleBasicOp lore = RuleBasicOp lore (TopDown lore)
type TopDownRuleIf lore = RuleIf lore (TopDown lore)
type TopDownRuleDoLoop lore = RuleDoLoop lore (TopDown lore)
type TopDownRuleOp lore = RuleOp lore (TopDown lore)
type TopDownRule lore = SimplificationRule lore (TopDown lore)

-- | Context for a rule applied during bottom-up traversal of the
-- program.  Takes a symbol table and usage table as arguments.
type BottomUp lore = (ST.SymbolTable lore, UT.UsageTable)

type BottomUpRuleGeneric lore = RuleGeneric lore (BottomUp lore)
type BottomUpRuleBasicOp lore = RuleBasicOp lore (BottomUp lore)
type BottomUpRuleIf lore = RuleIf lore (BottomUp lore)
type BottomUpRuleDoLoop lore = RuleDoLoop lore (BottomUp lore)
type BottomUpRuleOp lore = RuleOp lore (BottomUp lore)
type BottomUpRule lore = SimplificationRule lore (BottomUp lore)

-- | A collection of top-down rules.
type TopDownRules lore = Rules lore (TopDown lore)

-- | A collection of bottom-up rules.
type BottomUpRules lore = Rules lore (BottomUp lore)

-- | A collection of both top-down and bottom-up rules.
data RuleBook lore = RuleBook { bookTopDownRules :: TopDownRules lore
                              , bookBottomUpRules :: BottomUpRules lore
                              }

instance Semigroup (RuleBook lore) where
  RuleBook ts1 bs1 <> RuleBook ts2 bs2 = RuleBook (ts1<>ts2) (bs1<>bs2)

instance Monoid (RuleBook lore) where
  mempty = RuleBook mempty mempty

-- | Construct a rule book from a collection of rules.
ruleBook :: [TopDownRule m]
         -> [BottomUpRule m]
         -> RuleBook m
ruleBook topdowns bottomups =
  RuleBook (groupRules topdowns) (groupRules bottomups)
  where groupRules :: [SimplificationRule m a] -> Rules m a
        groupRules rs = Rules rs
                              (filter forBasicOp rs)
                              (filter forIf rs)
                              (filter forDoLoop rs)
                              (filter forOp rs)

        forBasicOp RuleBasicOp{} = True
        forBasicOp RuleGeneric{} = True
        forBasicOp _ = False

        forIf RuleIf{} = True
        forIf RuleGeneric{} = True
        forIf _ = False

        forDoLoop RuleDoLoop{} = True
        forDoLoop RuleGeneric{} = True
        forDoLoop _ = False

        forOp RuleOp{} = True
        forOp RuleGeneric{} = True
        forOp _ = False

-- | @simplifyStm lookup bnd@ performs simplification of the
-- binding @bnd@.  If simplification is possible, a replacement list
-- of bindings is returned, that bind at least the same names as the
-- original binding (and possibly more, for intermediate results).
topDownSimplifyStm :: (MonadFreshNames m, HasScope lore m) =>
                      RuleBook lore
                   -> ST.SymbolTable lore
                   -> Stm lore
                   -> m (Maybe (Stms lore))
topDownSimplifyStm = applyRules . bookTopDownRules

-- | @simplifyStm uses bnd@ performs simplification of the binding
-- @bnd@.  If simplification is possible, a replacement list of
-- bindings is returned, that bind at least the same names as the
-- original binding (and possibly more, for intermediate results).
-- The first argument is the set of names used after this binding.
bottomUpSimplifyStm :: (MonadFreshNames m, HasScope lore m) =>
                       RuleBook lore
                    -> (ST.SymbolTable lore, UT.UsageTable)
                    -> Stm lore
                    -> m (Maybe (Stms lore))
bottomUpSimplifyStm = applyRules . bookBottomUpRules

rulesForStm :: Stm lore -> Rules lore a -> [SimplificationRule lore a]
rulesForStm stm = case stmExp stm of BasicOp{} -> rulesBasicOp
                                     DoLoop{} -> rulesDoLoop
                                     Op{} -> rulesOp
                                     If{} -> rulesIf
                                     _ -> rulesAny

applyRule :: SimplificationRule lore a -> a -> Stm lore -> Rule lore
applyRule (RuleGeneric f) a stm = f a stm
applyRule (RuleBasicOp f) a (Let pat aux (BasicOp e)) = f a pat aux e
applyRule (RuleDoLoop f) a (Let pat aux (DoLoop ctx val form body)) =
  f a pat aux (ctx, val, form, body)
applyRule (RuleIf f) a (Let pat aux (If cond tbody fbody ifsort)) =
  f a pat aux (cond, tbody, fbody, ifsort)
applyRule (RuleOp f) a (Let pat aux (Op op)) =
  f a pat aux op
applyRule _ _ _ =
  Skip

applyRules :: (MonadFreshNames m, HasScope lore m) =>
              Rules lore a -> a -> Stm lore
           -> m (Maybe (Stms lore))
applyRules all_rules context stm = do
  scope <- askScope

  modifyNameSource $ \src ->
    let applyRules' []  = Nothing
        applyRules' (rule:rules) =
          case simplify scope src (applyRule rule context stm) of
            Just x -> Just x
            Nothing -> applyRules' rules

    in case applyRules' $ rulesForStm stm all_rules of
         Just (stms, src') -> (Just stms, src')
         Nothing           -> (Nothing, src)
