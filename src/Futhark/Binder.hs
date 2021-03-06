{-# LANGUAGE FlexibleContexts, GeneralizedNewtypeDeriving, TypeFamilies, FlexibleInstances, MultiParamTypeClasses, UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds #-}
-- | This module defines a convenience monad/typeclass for creating
-- normalised programs.
module Futhark.Binder
  ( -- * A concrete @MonadBinder@ monad.
    BinderT
  , runBinderT, runBinderT_
  , runBinderT', runBinderT'_
  , BinderOps (..)
  , bindableMkExpDecB
  , bindableMkBodyB
  , bindableMkLetNamesB
  , Binder
  , runBinder
  , runBinder_
  , joinBinder
  , runBodyBinder
  -- * Non-class interface
  , addBinderStms
  , collectBinderStms
  -- * The 'MonadBinder' typeclass
  , module Futhark.Binder.Class
  )
where

import Control.Arrow (second)
import Control.Monad.Writer
import Control.Monad.State.Strict
import Control.Monad.Reader
import Control.Monad.Error.Class
import qualified Data.Map.Strict as M

import Futhark.Binder.Class
import Futhark.IR

class ASTLore lore => BinderOps lore where
  mkExpDecB :: (MonadBinder m, Lore m ~ lore) =>
                Pattern lore -> Exp lore -> m (ExpDec lore)
  mkBodyB :: (MonadBinder m, Lore m ~ lore) =>
             Stms lore -> Result -> m (Body lore)
  mkLetNamesB :: (MonadBinder m, Lore m ~ lore) =>
                 [VName] -> Exp lore -> m (Stm lore)

bindableMkExpDecB :: (MonadBinder m, Bindable (Lore m)) =>
                      Pattern (Lore m) -> Exp (Lore m) -> m (ExpDec (Lore m))
bindableMkExpDecB pat e = return $ mkExpDec pat e

bindableMkBodyB :: (MonadBinder m, Bindable (Lore m)) =>
                   Stms (Lore m) -> Result -> m (Body (Lore m))
bindableMkBodyB stms res = return $ mkBody stms res

bindableMkLetNamesB :: (MonadBinder m, Bindable (Lore m)) =>
                       [VName] -> Exp (Lore m) -> m (Stm (Lore m))
bindableMkLetNamesB = mkLetNames

newtype BinderT lore m a = BinderT (StateT (Stms lore, Scope lore) m a)
  deriving (Functor, Monad, Applicative)

instance MonadTrans (BinderT lore) where
  lift = BinderT . lift

type Binder lore = BinderT lore (State VNameSource)

instance MonadFreshNames m => MonadFreshNames (BinderT lore m) where
  getNameSource = lift getNameSource
  putNameSource = lift . putNameSource

instance (ASTLore lore, Monad m) =>
         HasScope lore (BinderT lore m) where
  lookupType name = do
    t <- BinderT $ gets $ M.lookup name . snd
    case t of
      Nothing -> error $ "BinderT.lookupType: unknown variable " ++ pretty name
      Just t' -> return $ typeOf t'
  askScope = BinderT $ gets snd

instance (ASTLore lore, Monad m) =>
         LocalScope lore (BinderT lore m) where
  localScope types (BinderT m) = BinderT $ do
    modify $ second (M.union types)
    x <- m
    modify $ second (`M.difference` types)
    return x

instance (ASTLore lore, MonadFreshNames m, BinderOps lore) =>
         MonadBinder (BinderT lore m) where
  type Lore (BinderT lore m) = lore
  mkExpDecM = mkExpDecB
  mkBodyM = mkBodyB
  mkLetNamesM = mkLetNamesB

  addStms     = addBinderStms
  collectStms = collectBinderStms

runBinderT :: MonadFreshNames m =>
              BinderT lore m a
           -> Scope lore
           -> m (a, Stms lore)
runBinderT (BinderT m) scope = do
  (x, (stms, _)) <- runStateT m (mempty, scope)
  return (x, stms)

runBinderT_ :: MonadFreshNames m =>
                BinderT lore m a -> Scope lore -> m (Stms lore)
runBinderT_ m = fmap snd . runBinderT m

runBinderT' :: (MonadFreshNames m, HasScope somelore m, SameScope somelore lore) =>
               BinderT lore m a
            -> m (a, Stms lore)
runBinderT' m = do
  scope <- askScope
  runBinderT m $ castScope scope

runBinderT'_ :: (MonadFreshNames m, HasScope somelore m, SameScope somelore lore) =>
                BinderT lore m a -> m (Stms lore)
runBinderT'_ = fmap snd . runBinderT'

runBinder :: (MonadFreshNames m,
              HasScope somelore m, SameScope somelore lore) =>
              Binder lore a
           -> m (a, Stms lore)
runBinder m = do
  types <- askScope
  modifyNameSource $ runState $ runBinderT m $ castScope types

-- | Like 'runBinder', but throw away the result and just return the
-- added bindings.
runBinder_ :: (MonadFreshNames m,
               HasScope somelore m, SameScope somelore lore) =>
              Binder lore a
           -> m (Stms lore)
runBinder_ = fmap snd . runBinder

-- | As 'runBinder', but uses 'addStm' to add the returned
-- bindings to the surrounding monad.
joinBinder :: MonadBinder m => Binder (Lore m) a -> m a
joinBinder m = do (x, bnds) <- runBinder m
                  addStms bnds
                  return x

runBodyBinder :: (Bindable lore, MonadFreshNames m,
                  HasScope somelore m, SameScope somelore lore) =>
                 Binder lore (Body lore) -> m (Body lore)
runBodyBinder = fmap (uncurry $ flip insertStms) . runBinder

addBinderStms :: Monad m =>
                 Stms lore -> BinderT lore m ()
addBinderStms stms = BinderT $
  modify $ \(cur_stms,scope) -> (cur_stms<>stms,
                                 scope `M.union` scopeOf stms)

collectBinderStms :: Monad m =>
                     BinderT lore m a
                  -> BinderT lore m (a, Stms lore)
collectBinderStms m = do
  (old_stms, old_scope) <- BinderT get
  BinderT $ put (mempty, old_scope)
  x <- m
  (new_stms, _) <- BinderT get
  BinderT $ put (old_stms, old_scope)
  return (x, new_stms)

-- Utility instance defintions for MTL classes.  These require
-- UndecidableInstances, but save on typing elsewhere.

mapInner :: Monad m =>
            (m (a, (Stms lore, Scope lore))
             -> m (b, (Stms lore, Scope lore)))
         -> BinderT lore m a -> BinderT lore m b
mapInner f (BinderT m) = BinderT $ do
  s <- get
  (x, s') <- lift $ f $ runStateT m s
  put s'
  return x

instance MonadReader r m => MonadReader r (BinderT lore m) where
  ask = BinderT $ lift ask
  local f = mapInner $ local f

instance MonadState s m => MonadState s (BinderT lore m) where
  get = BinderT $ lift get
  put = BinderT . lift . put

instance MonadWriter w m => MonadWriter w (BinderT lore m) where
  tell = BinderT . lift . tell
  pass = mapInner $ \m -> pass $ do
    ((x, f), s) <- m
    return ((x, s), f)
  listen = mapInner $ \m -> do
    ((x, s), y) <- listen m
    return ((x, y), s)

instance MonadError e m => MonadError e (BinderT lore m) where
  throwError = lift . throwError
  catchError (BinderT m) f =
    BinderT $ catchError m $ unBinder . f
    where unBinder (BinderT m') = m'
