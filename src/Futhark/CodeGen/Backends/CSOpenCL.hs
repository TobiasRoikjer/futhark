{-# LANGUAGE FlexibleContexts #-}
module Futhark.CodeGen.Backends.CSOpenCL
  ( compileProg
  ) where

import Control.Monad
import Data.List (intersperse)

import Futhark.IR.KernelsMem (Prog, KernelsMem, int32)
import Futhark.CodeGen.Backends.CSOpenCL.Boilerplate
import qualified Futhark.CodeGen.Backends.GenericCSharp as CS
import qualified Futhark.CodeGen.ImpCode.OpenCL as Imp
import qualified Futhark.CodeGen.ImpGen.OpenCL as ImpGen
import Futhark.CodeGen.Backends.GenericCSharp.AST
import Futhark.CodeGen.Backends.GenericCSharp.Options
import Futhark.CodeGen.Backends.GenericCSharp.Definitions
import Futhark.Util (zEncodeString)
import Futhark.MonadFreshNames


compileProg :: MonadFreshNames m =>
               Maybe String -> Prog KernelsMem -> m String
compileProg module_name prog = do
  Imp.Program opencl_code opencl_prelude kernel_names types sizes failures prog' <-
    ImpGen.compileProg prog
  CS.compileProg
    module_name
    CS.emptyConstructor
    imports
    defines
    operations
    ()
    (generateBoilerplate opencl_code opencl_prelude kernel_names types sizes failures)
    []
    [Imp.Space "device", Imp.Space "local", Imp.DefaultSpace]
    cliOptions
    prog'

  where operations :: CS.Operations Imp.OpenCL ()
        operations = CS.defaultOperations
                     { CS.opsCompiler = callKernel
                     , CS.opsWriteScalar = writeOpenCLScalar
                     , CS.opsReadScalar = readOpenCLScalar
                     , CS.opsAllocate = allocateOpenCLBuffer
                     , CS.opsCopy = copyOpenCLMemory
                     , CS.opsStaticArray = staticOpenCLArray
                     , CS.opsEntryInput = unpackArrayInput
                     , CS.opsEntryOutput = packArrayOutput
                     , CS.opsSyncRun = futharkSyncContext
                     }
        imports = [ Using Nothing "System.Runtime.CompilerServices"
                  , Using Nothing "Cloo"
                  , Using Nothing "Cloo.Bindings" ]
        defines = [ Escape csOpenCL
                  , Escape csMemoryOpenCL ]
cliOptions :: [Option]
cliOptions = [ Option { optionLongName = "platform"
                      , optionShortName = Just 'p'
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkContextConfigSetPlatform(ref Cfg, optarg);"]
                      }
             , Option { optionLongName = "device"
                      , optionShortName = Just 'd'
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkContextConfigSetDevice(ref Cfg, optarg);"]
                      }
             , Option { optionLongName = "dump-opencl"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkContextConfigDumpProgramTo(ref Cfg, optarg);"]
                      }
             , Option { optionLongName = "load-opencl"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkContextConfigLoadProgramFrom(ref Cfg, optarg);"]
                      }
             , Option { optionLongName = "debugging"
                      , optionShortName = Just 'D'
                      , optionArgument = NoArgument
                      , optionAction = [Escape "FutharkContextConfigSetDebugging(ref Cfg, true);"]
                      }
             , Option { optionLongName = "default-group-size"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkContextConfigSetDefaultGroupSize(ref Cfg, Convert.ToInt32(optarg));"]
                      }
             , Option { optionLongName = "default-num-groups"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkContextConfigSetDefaultNumGroups(ref Cfg, Convert.ToInt32(optarg));"]
                      }
             , Option { optionLongName = "default-tile-size"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkContextConfigSetDefaultTileSize(ref Cfg, Convert.ToInt32(optarg));"]
                      }
             , Option { optionLongName = "default-threshold"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkContextConfigSetDefaultThreshold(ref Cfg, Convert.ToInt32(optarg));"]
                      }
             , Option { optionLongName = "print-sizes"
                      , optionShortName = Nothing
                      , optionArgument = NoArgument
                      , optionAction = [Escape "FutharkConfigPrintSizes();"]
                      }
             , Option { optionLongName = "size"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkConfigSetSize(ref Cfg, optarg);"]
                      }
             , Option { optionLongName = "tuning"
                      , optionShortName = Nothing
                      , optionArgument = RequiredArgument
                      , optionAction = [Escape "FutharkConfigLoadTuning(ref Cfg, optarg);"]
                      }
             ]

callKernel :: CS.OpCompiler Imp.OpenCL ()
callKernel (Imp.GetSize v key) =
  CS.stm $ Reassign (Var (CS.compileName v)) $
    Field (Var "Ctx.Sizes") $ zEncodeString $ pretty key

callKernel (Imp.GetSizeMax v size_class) = do
  v' <- CS.compileVar v
  CS.stm $ Reassign v' $
    Field (Var "Ctx.OpenCL") $
    case size_class of Imp.SizeGroup -> "MaxGroupSize"
                       Imp.SizeNumGroups -> "MaxNumGroups"
                       Imp.SizeTile -> "MaxTileSize"
                       Imp.SizeThreshold{} -> "MaxThreshold"
                       Imp.SizeLocalMemory -> "MaxLocalMemory"
                       Imp.SizeBespoke{} -> "MaxBespoke"

callKernel (Imp.LaunchKernel safety name args num_workgroups workgroup_size) = do
  num_workgroups' <- mapM CS.compileExp num_workgroups
  workgroup_size' <- mapM CS.compileExp workgroup_size
  let kernel_size = zipWith mult_exp num_workgroups' workgroup_size'
      total_elements = foldl mult_exp (Integer 1) kernel_size
      cond = BinOp "!=" total_elements (Integer 0)
  body <- CS.collect $ launchKernel safety name kernel_size workgroup_size' args
  CS.stm $ If cond body []
  where mult_exp = BinOp "*"

callKernel (Imp.CmpSizeLe v key x) = do
  v' <- CS.compileVar v
  x' <- CS.compileExp x
  CS.stm $ Reassign v' $
    BinOp "<=" (Field (Var "Ctx.Sizes") (zEncodeString $ pretty key)) x'

launchKernel :: Imp.Safety -> String -> [CSExp] -> [CSExp] -> [Imp.KernelArg] -> CS.CompilerM op s ()
launchKernel safety kernel_name kernel_dims workgroup_dims args = do
  let kernel_name' = "Ctx."++kernel_name

  let failure_args =
        [ processMemArg kernel_name' 0 $ Var "Ctx.GlobalFailure"
        , processValueArg kernel_name' 1 int32 $ Var "Ctx.GlobalFailureIsAnOption"
        , processMemArg kernel_name' 2 $ Var "Ctx.GlobalFailureArgs"]

  failure_args' <- concat <$> sequence (take (Imp.numFailureParams safety) failure_args)

  args_stms <- zipWithM (processKernelArg kernel_name')
               [toInteger (Imp.numFailureParams safety)..] args
  CS.stm $ Unsafe $ failure_args' ++ concat args_stms

  global_work_size <- newVName' "GlobalWorkSize"
  local_work_size <- newVName' "LocalWorkSize"
  stop_watch <- newVName' "StopWatch"
  time_diff <- newVName' "TimeDiff"

  let debugStartStmts =
        map Exp $ [CS.consoleErrorWrite "Launching {0} with global work size [" [String kernel_name]] ++
                  printKernelSize global_work_size ++
                  [ CS.consoleErrorWrite "] and local work size [" []] ++
                  printKernelSize local_work_size ++
                  [ CS.consoleErrorWrite "].\n" []
                  , CallMethod (Var stop_watch) (Var "Start") []]

  let ctx = (++) "Ctx."
  let debugEndStmts =
          [ Exp $ CS.simpleCall "FutharkContextSync" []
          , Exp $ CallMethod (Var stop_watch) (Var "Stop") []
          , Assign (Var time_diff) $ asMicroseconds (Var stop_watch)
          , AssignOp "+" (Var $ ctx $ kernelRuntime kernel_name) (Var time_diff)
          , AssignOp "+" (Var $ ctx $ kernelRuns kernel_name) (Integer 1)
          , Exp $ CS.consoleErrorWriteLine "kernel {0} runtime: {1}" [String kernel_name, Var time_diff]
          ]


  CS.stm $ If (BinOp "!=" total_elements (Integer 0))
    ([ Assign (Var global_work_size) (Collection "IntPtr[]" $ map CS.toIntPtr kernel_dims)
     , Assign (Var local_work_size) (Collection "IntPtr[]" $ map CS.toIntPtr workgroup_dims)
     , Assign (Var stop_watch) $ CS.simpleInitClass "Stopwatch" []
     , If (Var "Ctx.Debugging") debugStartStmts []
     ]
     ++
     [ Exp $ CS.simpleCall "OPENCL_SUCCEED" [
         CS.simpleCall "CL10.EnqueueNDRangeKernel"
           [ Var "Ctx.OpenCL.Queue", Var kernel_name', Integer kernel_rank, Null
           , Var global_work_size, Var local_work_size, Integer 0, Null, Null]]]
     ++
     [ If (Var "Ctx.Debugging") debugEndStmts [] ]) []

  when (safety >= Imp.SafetyFull) $
    CS.stm $ Reassign (Var "Ctx.GlobalFailureIsAnOption") (Integer 1)

  finishIfSynchronous

  where processMemArg kernel argnum mem = do
          err <- newVName' "setargErr"
          dest <- newVName "kArgDest"
          let err_var = Var err
          dest' <- CS.compileVar dest
          return [ Fixed dest' (Addr mem)
                   [ Assign err_var $ getKernelCall kernel argnum
                     (CS.sizeOf $ Primitive IntPtrT) dest']
                 ]

        processValueArg kernel argnum et e = do
          let t = CS.compilePrimTypeToAST et
          tmp <- newVName' "kernelArg"
          err <- newVName' "setargErr"
          let err_var = Var err
          return [ AssignTyped t (Var tmp) (Just e)
                 , Assign err_var $ getKernelCall kernel argnum (CS.sizeOf t) (Addr $ Var tmp)]

        processKernelArg :: String
                         -> Integer
                         -> Imp.KernelArg
                         -> CS.CompilerM op s [CSStmt]
        processKernelArg kernel argnum (Imp.ValueKArg e et) =
          processValueArg kernel argnum et =<< CS.compileExp e
        processKernelArg kernel argnum (Imp.MemKArg v) =
          processMemArg kernel argnum . memblockFromMem =<< CS.compileVar v

        processKernelArg kernel argnum (Imp.SharedMemoryKArg (Imp.Count num_bytes)) = do
          err <- newVName' "setargErr"
          let err_var = Var err
          num_bytes' <- CS.compileExp num_bytes
          return [ Assign err_var $ getKernelCall kernel argnum num_bytes' Null ]

        kernel_rank = toInteger $ length kernel_dims
        total_elements = foldl (BinOp "*") (Integer 1) kernel_dims

        printKernelSize :: String -> [CSExp]
        printKernelSize work_size =
          intersperse (CS.consoleErrorWrite ", " []) $ map (printKernelDim work_size) [0..kernel_rank-1]

        printKernelDim global_work_size i =
          CS.consoleErrorWrite "{0}" [Index (Var global_work_size) (IdxExp (Integer $ toInteger i))]

        asMicroseconds watch =
          BinOp "/" (Field watch "ElapsedTicks")
          (BinOp "/" (Field (Var "TimeSpan") "TicksPerMillisecond") (Integer 1000))



getKernelCall :: String -> Integer -> CSExp -> CSExp -> CSExp
getKernelCall kernel arg_num size Null =
  CS.simpleCall "CL10.SetKernelArg" [ Var kernel, Integer arg_num, CS.toIntPtr size, Var "Ctx.NULL"]
getKernelCall kernel arg_num size e =
  CS.simpleCall "CL10.SetKernelArg" [ Var kernel, Integer arg_num, CS.toIntPtr size, CS.toIntPtr e]

writeOpenCLScalar :: CS.WriteScalar Imp.OpenCL ()
writeOpenCLScalar mem i bt "device" val = do
  let bt' = CS.compilePrimTypeToAST bt
  scalar <- newVName' "scalar"
  ptr <- newVName' "ptr"
  CS.stm $ Unsafe
    [ AssignTyped bt' (Var scalar) (Just val)
    , AssignTyped (PointerT VoidT) (Var ptr) (Just $ Addr $ Var scalar)
    , Exp $ CS.simpleCall "CL10.EnqueueWriteBuffer"
        [ Var "Ctx.OpenCL.Queue", memblockFromMem mem, Bool True
        , CS.toIntPtr $ BinOp "*" i (CS.sizeOf bt')
        , CS.toIntPtr $ CS.sizeOf bt',CS.toIntPtr $ Var ptr
    , Integer 0, Null, Null]
    ]

writeOpenCLScalar _ _ _ space _ =
  error $ "Cannot write to '" ++ space ++ "' memory space."

readOpenCLScalar :: CS.ReadScalar Imp.OpenCL ()
readOpenCLScalar mem i bt "device" = do
  val <- newVName' "read_res"
  ptr <- newVName' "ptr"
  let bt' = CS.compilePrimTypeToAST bt
  CS.stm $ AssignTyped bt' (Var val) (Just $ CS.simpleInitClass (pretty bt') [])
  CS.stm $ Unsafe
    [ CS.assignScalarPointer (Var val) (Var ptr)
    , Exp $ CS.simpleCall "CL10.EnqueueReadBuffer"
      [ Var "Ctx.OpenCL.Queue", memblockFromMem mem , Bool True
      , CS.toIntPtr $ BinOp "*" i (CS.sizeOf bt')
      , CS.toIntPtr $ CS.sizeOf bt', CS.toIntPtr $ Var ptr
      , Integer 0, Null, Null]
    ]
  return $ Var val

readOpenCLScalar _ _ _ space =
  error $ "Cannot read from '" ++ space ++ "' memory space."

computeErrCodeT :: CSType
computeErrCodeT = CustomT "ComputeErrorCode"

allocateOpenCLBuffer :: CS.Allocate Imp.OpenCL ()
allocateOpenCLBuffer mem size "device" = do
  errcode <- CS.compileName <$> newVName "errCode"
  CS.stm $ AssignTyped computeErrCodeT (Var errcode) Nothing
  CS.stm $ Reassign mem (CS.simpleCall "MemblockAllocDevice" [Ref $ Var "Ctx", mem, size, String $ pretty mem])

allocateOpenCLBuffer _ _ space =
  error $ "Cannot allocate in '" ++ space ++ "' space"

copyOpenCLMemory :: CS.Copy Imp.OpenCL ()
copyOpenCLMemory destmem destidx Imp.DefaultSpace srcmem srcidx (Imp.Space "device") nbytes _ = do
  ptr <- newVName' "ptr"
  CS.stm $ Fixed (Var ptr) (Addr $ Index destmem $ IdxExp $ Integer 0)
    [ ifNotZeroSize nbytes $
      Exp $ CS.simpleCall "CL10.EnqueueReadBuffer"
      [ Var "Ctx.Opencl.Queue", memblockFromMem srcmem, Bool True
      , CS.toIntPtr srcidx, nbytes,CS.toIntPtr $ Var ptr
      , CS.toIntPtr destidx, Null, Null]
    ]

copyOpenCLMemory destmem destidx (Imp.Space "device") srcmem srcidx Imp.DefaultSpace nbytes _ = do
  ptr <- newVName' "ptr"
  CS.stm $ Fixed (Var ptr) (Addr $ Index srcmem $ IdxExp $ Integer 0)
    [ ifNotZeroSize nbytes $
      Exp $ CS.simpleCall "CL10.EnqueueWriteBuffer"
        [ Var "Ctx.OpenCL.Queue", memblockFromMem destmem, Bool True
        , CS.toIntPtr destidx, CS.toIntPtr nbytes, CS.toIntPtr $ Var ptr
        , srcidx, Null, Null]
    ]

copyOpenCLMemory destmem destidx (Imp.Space "device") srcmem srcidx (Imp.Space "device") nbytes _ = do
  CS.stm $ ifNotZeroSize nbytes $
    Exp $ CS.simpleCall "CL10.EnqueueCopyBuffer"
      [ Var "Ctx.OpenCL.Queue", memblockFromMem srcmem, memblockFromMem destmem
      , CS.toIntPtr srcidx, CS.toIntPtr destidx, CS.toIntPtr nbytes
      , Integer 0, Null, Null]
  finishIfSynchronous

copyOpenCLMemory destmem destidx Imp.DefaultSpace srcmem srcidx Imp.DefaultSpace nbytes _ =
  CS.copyMemoryDefaultSpace destmem destidx srcmem srcidx nbytes

copyOpenCLMemory _ _ destspace _ _ srcspace _ _=
  error $ "Cannot copy to " ++ show destspace ++ " from " ++ show srcspace

staticOpenCLArray :: CS.StaticArray Imp.OpenCL ()
staticOpenCLArray name "device" t vs = do
  name' <- CS.compileVar name
  CS.staticMemDecl $ AssignTyped (CustomT "OpenCLMemblock") name' Nothing

  -- Create host-side C# array with intended values.
  tmp_arr <- newVName' "tmpArr"
  let t' = CS.compilePrimTypeToAST t
  CS.staticMemDecl $ AssignTyped (Composite $ ArrayT t') (Var tmp_arr) $ Just $
    case vs of Imp.ArrayValues vs' ->
                 CreateArray (CS.compilePrimTypeToAST t) $ Right $ map CS.compilePrimValue vs'
               Imp.ArrayZeros n ->
                 CreateArray (CS.compilePrimTypeToAST t) $ Left n

  -- Create memory block on the device.
  ptr <- newVName' "ptr"
  let num_elems = case vs of Imp.ArrayValues vs' -> length vs'
                             Imp.ArrayZeros n -> n
      size = Integer $ toInteger num_elems * Imp.primByteSize t

  CS.staticMemAlloc $ Reassign name' $
    CS.simpleCall "EmptyMemblock" [Var "Ctx.EMPTY_MEM_HANDLE"]
  errcode <- CS.compileName <$> newVName "errCode"
  CS.staticMemAlloc $ AssignTyped computeErrCodeT (Var errcode) Nothing
  CS.staticMemAlloc $ Reassign name' $
    CS.simpleCall "MemblockAllocDevice"
    [Ref $ Var "Ctx", name', size, String $ pretty name']

  -- Copy Numpy array to the device memory block.
  CS.staticMemAlloc $ Unsafe [
    Fixed (Var ptr) (Addr $ Index (Var tmp_arr) $ IdxExp $ Integer 0)
      [ ifNotZeroSize size $
        Exp $ CS.simpleCall "CL10.EnqueueWriteBuffer"
          [ Var "Ctx.OpenCL.Queue", memblockFromMem name', Bool True
          , CS.toIntPtr (Integer 0),CS.toIntPtr size
          , CS.toIntPtr $ Var ptr, Integer 0, Null, Null ]
      ]
    ]

staticOpenCLArray _ space _ _ =
  error $ "CSOpenCL backend cannot create static array in memory space '" ++ space ++ "'"

memblockFromMem :: CSExp -> CSExp
memblockFromMem mem = Field mem "Mem"

packArrayOutput :: CS.EntryOutput Imp.OpenCL ()
packArrayOutput mem "device" bt ept dims = do
  let size = foldr (BinOp "*") (Integer 1) dims'
  let bt' = CS.compilePrimTypeToASText bt ept
  let nbytes = BinOp "*" (CS.sizeOf bt') size
  let createTuple = "createTuple_"++ pretty bt'

  return $ CS.simpleCall createTuple [ memblockFromMem mem, Var "Ctx.OpenCL.Queue", nbytes
                                     , CreateArray (Primitive $ CSInt Int64T) $ Right dims']
  where dims' = map CS.compileDim dims

packArrayOutput _ sid _ _ _ =
  error $ "Cannot return array from " ++ sid ++ " space."

unpackArrayInput :: CS.EntryInput Imp.OpenCL ()
unpackArrayInput mem "device" t _ dims e = do
  let size = foldr (BinOp "*") (Integer 1) dims'
  let t' = CS.compilePrimTypeToAST t
  let nbytes = BinOp "*" (CS.sizeOf t') size
  zipWithM_ (CS.unpackDim e) dims [0..]
  ptr <- pretty <$> newVName "ptr"

  mem' <- CS.compileVar mem
  CS.stm $ CS.getDefaultDecl (Imp.MemParam mem (Imp.Space "device"))
  allocateOpenCLBuffer mem' nbytes "device"
  CS.stm $ Unsafe [Fixed (Var ptr) (Addr $ Index (Field e "Item1") $ IdxExp $ Integer 0)
      [ ifNotZeroSize nbytes $
        Exp $ CS.simpleCall "CL10.EnqueueWriteBuffer"
        [ Var "Ctx.OpenCL.Queue", memblockFromMem mem', Bool True
        , CS.toIntPtr (Integer 0), CS.toIntPtr nbytes, CS.toIntPtr (Var ptr)
        , Integer 0, Null, Null]
      ]]

  where dims' = map CS.compileDim dims

unpackArrayInput _ sid _ _ _ _ =
  error $ "Cannot accept array from " ++ sid ++ " space."

futharkSyncContext :: CSStmt
futharkSyncContext = Exp $ CS.simpleCall "FutharkContextSync" []

ifNotZeroSize :: CSExp -> CSStmt -> CSStmt
ifNotZeroSize e s =
  If (BinOp "!=" e (Integer 0)) [s] []

finishIfSynchronous :: CS.CompilerM op s ()
finishIfSynchronous =
  CS.stm $ If (Var "Synchronous") [Exp $ CS.simpleCall "CL10.Finish" [Var "Ctx.OpenCL.Queue"]] []

newVName' :: MonadFreshNames f => String -> f String
newVName' s = CS.compileName <$> newVName s
