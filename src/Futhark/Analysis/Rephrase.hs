{-# LANGUAGE GADTs #-}
{-# LANGUAGE ConstraintKinds #-}
-- | Facilities for changing the lore of some fragment, with no context.
module Futhark.Analysis.Rephrase
       ( rephraseProg
       , rephraseFunDef
       , rephraseExp
       , rephraseBody
       , rephraseStm
       , rephraseLambda
       , rephrasePattern
       , rephrasePatElem
       , Rephraser (..)
       )
where

import Futhark.IR

data Rephraser m from to
  = Rephraser { rephraseExpLore :: ExpDec from -> m (ExpDec to)
              , rephraseLetBoundLore :: LetDec from -> m (LetDec to)
              , rephraseFParamLore :: FParamInfo from -> m (FParamInfo to)
              , rephraseLParamLore :: LParamInfo from -> m (LParamInfo to)
              , rephraseBodyLore :: BodyDec from -> m (BodyDec to)
              , rephraseRetType :: RetType from -> m (RetType to)
              , rephraseBranchType :: BranchType from -> m (BranchType to)
              , rephraseOp :: Op from -> m (Op to)
              }

rephraseProg :: Monad m => Rephraser m from to -> Prog from -> m (Prog to)
rephraseProg rephraser (Prog consts funs) =
  Prog
  <$> mapM (rephraseStm rephraser) consts
  <*> mapM (rephraseFunDef rephraser) funs

rephraseFunDef :: Monad m => Rephraser m from to -> FunDef from -> m (FunDef to)
rephraseFunDef rephraser fundec = do
  body' <- rephraseBody rephraser $ funDefBody fundec
  params' <- mapM (rephraseParam $ rephraseFParamLore rephraser) $ funDefParams fundec
  rettype' <- mapM (rephraseRetType rephraser) $ funDefRetType fundec
  return fundec { funDefBody = body', funDefParams = params', funDefRetType = rettype' }

rephraseExp :: Monad m => Rephraser m from to -> Exp from -> m (Exp to)
rephraseExp = mapExpM . mapper

rephraseStm :: Monad m => Rephraser m from to -> Stm from -> m (Stm to)
rephraseStm rephraser (Let pat (StmAux cs attrs dec) e) =
  Let <$>
  rephrasePattern (rephraseLetBoundLore rephraser) pat <*>
  (StmAux cs attrs <$> rephraseExpLore rephraser dec) <*>
  rephraseExp rephraser e

rephrasePattern :: Monad m =>
                   (from -> m to)
                -> PatternT from
                -> m (PatternT to)
rephrasePattern f (Pattern context values) =
  Pattern <$> rephrase context <*> rephrase values
  where rephrase = mapM $ rephrasePatElem f

rephrasePatElem :: Monad m => (from -> m to) -> PatElemT from -> m (PatElemT to)
rephrasePatElem rephraser (PatElem ident from) =
  PatElem ident <$> rephraser from

rephraseParam :: Monad m => (from -> m to) -> Param from -> m (Param to)
rephraseParam rephraser (Param name from) =
  Param name <$> rephraser from

rephraseBody :: Monad m => Rephraser m from to -> Body from -> m (Body to)
rephraseBody rephraser (Body lore bnds res) =
  Body <$>
  rephraseBodyLore rephraser lore <*>
  (stmsFromList <$> mapM (rephraseStm rephraser) (stmsToList bnds)) <*>
  pure res

rephraseLambda :: Monad m => Rephraser m from to -> Lambda from -> m (Lambda to)
rephraseLambda rephraser lam = do
  body' <- rephraseBody rephraser $ lambdaBody lam
  params' <- mapM (rephraseParam $ rephraseLParamLore rephraser) $ lambdaParams lam
  return lam { lambdaBody = body', lambdaParams = params' }

mapper :: Monad m => Rephraser m from to -> Mapper from to m
mapper rephraser = identityMapper {
    mapOnBody = const $ rephraseBody rephraser
  , mapOnRetType = rephraseRetType rephraser
  , mapOnBranchType = rephraseBranchType rephraser
  , mapOnFParam = rephraseParam (rephraseFParamLore rephraser)
  , mapOnLParam = rephraseParam (rephraseLParamLore rephraser)
  , mapOnOp = rephraseOp rephraser
  }
