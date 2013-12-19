-- | Bohrium code generator.
module L0C.Backends.Bohrium (compileProg) where

import Control.Monad

import L0C.L0
import qualified L0C.FirstOrderTransform as FOT
import L0C.Backends.BohriumCodeGen

import qualified L0C.Backends.GenericC as GenericC

compileProg :: Prog -> String
compileProg = addHeader . GenericC.compileProg expCompiler
  where expCompiler target e = do
          res <- compileExp target e
          case res of Nothing   -> liftM Left $ FOT.transformExp FOT.noRecursion e
                      Just res' -> return $ Right res'
        addHeader = ("#include <bh_c.h>\n"++)
