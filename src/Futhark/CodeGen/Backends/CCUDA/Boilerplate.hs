{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
module Futhark.CodeGen.Backends.CCUDA.Boilerplate
  (
    generateBoilerplate
  ) where

import qualified Language.C.Quote.OpenCL as C

import qualified Futhark.CodeGen.Backends.GenericC as GC
import Futhark.CodeGen.ImpCode.OpenCL
import Futhark.CodeGen.Backends.COpenCL.Boilerplate (failureSwitch)
import Futhark.Util (chunk, zEncodeString)

import qualified Data.Map as M
import Data.FileEmbed (embedStringFile)

errorMsgNumArgs :: ErrorMsg a -> Int
errorMsgNumArgs = length . errorMsgArgTypes

generateBoilerplate :: String -> String -> M.Map KernelName Safety
                    -> M.Map Name SizeClass
                    -> [FailureMsg]
                    -> GC.CompilerM OpenCL () ()
generateBoilerplate cuda_program cuda_prelude kernels sizes failures = do
  mapM_ GC.earlyDecl [C.cunit|
      $esc:("#include <cuda.h>")
      $esc:("#include <nvrtc.h>")
      $esc:("typedef CUdeviceptr fl_mem_t;")
      $esc:free_list_h
      $esc:cuda_h
      const char *cuda_program[] = {$inits:fragments, NULL};
      |]

  generateSizeFuns sizes
  cfg <- generateConfigFuns sizes
  generateContextFuns cfg kernels sizes failures
  where
    cuda_h = $(embedStringFile "rts/c/cuda.h")
    free_list_h = $(embedStringFile "rts/c/free_list.h")
    fragments = map (\s -> [C.cinit|$string:s|])
                  $ chunk 2000 (cuda_prelude ++ cuda_program)

generateSizeFuns :: M.Map Name SizeClass -> GC.CompilerM OpenCL () ()
generateSizeFuns sizes = do
  let size_name_inits = map (\k -> [C.cinit|$string:(pretty k)|]) $ M.keys sizes
      size_var_inits = map (\k -> [C.cinit|$string:(zEncodeString (pretty k))|]) $ M.keys sizes
      size_class_inits = map (\c -> [C.cinit|$string:(pretty c)|]) $ M.elems sizes
      num_sizes = M.size sizes

  GC.earlyDecl [C.cedecl|static const char *size_names[] = { $inits:size_name_inits };|]
  GC.earlyDecl [C.cedecl|static const char *size_vars[] = { $inits:size_var_inits };|]
  GC.earlyDecl [C.cedecl|static const char *size_classes[] = { $inits:size_class_inits };|]

  GC.publicDef_ "get_num_sizes" GC.InitDecl $ \s ->
    ([C.cedecl|int $id:s(void);|],
     [C.cedecl|int $id:s(void) {
                return $int:num_sizes;
              }|])

  GC.publicDef_ "get_size_name" GC.InitDecl $ \s ->
    ([C.cedecl|const char* $id:s(int);|],
     [C.cedecl|const char* $id:s(int i) {
                return size_names[i];
              }|])

  GC.publicDef_ "get_size_class" GC.InitDecl $ \s ->
    ([C.cedecl|const char* $id:s(int);|],
     [C.cedecl|const char* $id:s(int i) {
                return size_classes[i];
              }|])

generateConfigFuns :: M.Map Name SizeClass -> GC.CompilerM OpenCL () String
generateConfigFuns sizes = do
  let size_decls = map (\k -> [C.csdecl|size_t $id:k;|]) $ M.keys sizes
      num_sizes = M.size sizes
  GC.earlyDecl [C.cedecl|struct sizes { $sdecls:size_decls };|]
  cfg <- GC.publicDef "context_config" GC.InitDecl $ \s ->
    ([C.cedecl|struct $id:s;|],
     [C.cedecl|struct $id:s { struct cuda_config cu_cfg;
                              size_t sizes[$int:num_sizes];
                              int num_nvrtc_opts;
                              const char **nvrtc_opts;
                            };|])

  let size_value_inits = zipWith sizeInit [0..M.size sizes-1] (M.elems sizes)
      sizeInit i size = [C.cstm|cfg->sizes[$int:i] = $int:val;|]
         where val = case size of SizeBespoke _ x -> x
                                  _               -> 0
  GC.publicDef_ "context_config_new" GC.InitDecl $ \s ->
    ([C.cedecl|struct $id:cfg* $id:s(void);|],
     [C.cedecl|struct $id:cfg* $id:s(void) {
                         struct $id:cfg *cfg = (struct $id:cfg*) malloc(sizeof(struct $id:cfg));
                         if (cfg == NULL) {
                           return NULL;
                         }

                         cfg->num_nvrtc_opts = 0;
                         cfg->nvrtc_opts = (const char**) malloc(sizeof(const char*));
                         cfg->nvrtc_opts[0] = NULL;
                         $stms:size_value_inits
                         cuda_config_init(&cfg->cu_cfg, $int:num_sizes,
                                          size_names, size_vars,
                                          cfg->sizes, size_classes);
                         return cfg;
                       }|])

  GC.publicDef_ "context_config_free" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg) {
                         free(cfg->nvrtc_opts);
                         free(cfg);
                       }|])

  GC.publicDef_ "context_config_add_nvrtc_option" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, const char *opt);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, const char *opt) {
                         cfg->nvrtc_opts[cfg->num_nvrtc_opts] = opt;
                         cfg->num_nvrtc_opts++;
                         cfg->nvrtc_opts = (const char**) realloc(cfg->nvrtc_opts, (cfg->num_nvrtc_opts+1) * sizeof(const char*));
                         cfg->nvrtc_opts[cfg->num_nvrtc_opts] = NULL;
                       }|])

  GC.publicDef_ "context_config_set_debugging" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, int flag) {
                         cfg->cu_cfg.logging = cfg->cu_cfg.debugging = flag;
                       }|])

  GC.publicDef_ "context_config_set_logging" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, int flag) {
                         cfg->cu_cfg.logging = flag;
                       }|])

  GC.publicDef_ "context_config_set_device" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, const char *s);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, const char *s) {
                         set_preferred_device(&cfg->cu_cfg, s);
                       }|])

  GC.publicDef_ "context_config_dump_program_to" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, const char *path);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, const char *path) {
                         cfg->cu_cfg.dump_program_to = path;
                       }|])

  GC.publicDef_ "context_config_load_program_from" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, const char *path);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, const char *path) {
                         cfg->cu_cfg.load_program_from = path;
                       }|])

  GC.publicDef_ "context_config_dump_ptx_to" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, const char *path);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, const char *path) {
                          cfg->cu_cfg.dump_ptx_to = path;
                      }|])

  GC.publicDef_ "context_config_load_ptx_from" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, const char *path);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, const char *path) {
                          cfg->cu_cfg.load_ptx_from = path;
                      }|])

  GC.publicDef_ "context_config_set_default_group_size" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, int size);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, int size) {
                         cfg->cu_cfg.default_block_size = size;
                         cfg->cu_cfg.default_block_size_changed = 1;
                       }|])

  GC.publicDef_ "context_config_set_default_num_groups" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, int num);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, int num) {
                         cfg->cu_cfg.default_grid_size = num;
                         cfg->cu_cfg.default_grid_size_changed = 1;
                       }|])

  GC.publicDef_ "context_config_set_default_tile_size" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, int num);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, int size) {
                         cfg->cu_cfg.default_tile_size = size;
                         cfg->cu_cfg.default_tile_size_changed = 1;
                       }|])

  GC.publicDef_ "context_config_set_default_threshold" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:cfg* cfg, int num);|],
     [C.cedecl|void $id:s(struct $id:cfg* cfg, int size) {
                         cfg->cu_cfg.default_threshold = size;
                       }|])

  GC.publicDef_ "context_config_set_size" GC.InitDecl $ \s ->
    ([C.cedecl|int $id:s(struct $id:cfg* cfg, const char *size_name, size_t size_value);|],
     [C.cedecl|int $id:s(struct $id:cfg* cfg, const char *size_name, size_t size_value) {

                         for (int i = 0; i < $int:num_sizes; i++) {
                           if (strcmp(size_name, size_names[i]) == 0) {
                             cfg->sizes[i] = size_value;
                             return 0;
                           }
                         }

                         if (strcmp(size_name, "default_group_size") == 0) {
                           cfg->cu_cfg.default_block_size = size_value;
                           return 0;
                         }

                         if (strcmp(size_name, "default_num_groups") == 0) {
                           cfg->cu_cfg.default_grid_size = size_value;
                           return 0;
                         }

                         if (strcmp(size_name, "default_threshold") == 0) {
                           cfg->cu_cfg.default_threshold = size_value;
                           return 0;
                         }

                         if (strcmp(size_name, "default_tile_size") == 0) {
                           cfg->cu_cfg.default_tile_size = size_value;
                           return 0;
                         }
                         return 1;
                       }|])
  return cfg

generateContextFuns :: String -> M.Map KernelName Safety
                    -> M.Map Name SizeClass
                    -> [FailureMsg]
                    -> GC.CompilerM OpenCL () ()
generateContextFuns cfg kernels sizes failures = do
  final_inits <- GC.contextFinalInits
  (fields, init_fields) <- GC.contextContents
  let kernel_fields = map (\k -> [C.csdecl|typename CUfunction $id:k;|]) $
                          M.keys kernels

  ctx <- GC.publicDef "context" GC.InitDecl $ \s ->
    ([C.cedecl|struct $id:s;|],
     [C.cedecl|struct $id:s {
                         int detail_memory;
                         int debugging;
                         int profiling;
                         int profiling_paused;
                         typename lock_t lock;
                         char *error;
                         $sdecls:fields
                         $sdecls:kernel_fields
                         typename CUdeviceptr global_failure;
                         typename CUdeviceptr global_failure_args;
                         struct cuda_context cuda;
                         struct sizes sizes;
                         // True if a potentially failing kernel has been enqueued.
                         typename int32_t failure_is_an_option;
                       };|])

  let set_sizes = zipWith (\i k -> [C.cstm|ctx->sizes.$id:k = cfg->sizes[$int:i];|])
                          [(0::Int)..] $ M.keys sizes
      max_failure_args =
        foldl max 0 $ map (errorMsgNumArgs . failureError) failures

  GC.publicDef_ "context_new" GC.InitDecl $ \s ->
    ([C.cedecl|struct $id:ctx* $id:s(struct $id:cfg* cfg);|],
     [C.cedecl|struct $id:ctx* $id:s(struct $id:cfg* cfg) {
                 struct $id:ctx* ctx = (struct $id:ctx*) malloc(sizeof(struct $id:ctx));
                 if (ctx == NULL) {
                   return NULL;
                 }
                 ctx->profiling = ctx->debugging = ctx->detail_memory = cfg->cu_cfg.debugging;
                 ctx->error = NULL;

                 ctx->cuda.cfg = cfg->cu_cfg;
                 create_lock(&ctx->lock);

                 ctx->failure_is_an_option = 0;
                 $stms:init_fields

                 cuda_setup(&ctx->cuda, cuda_program, cfg->nvrtc_opts);

                 typename int32_t no_error = -1;
                 CUDA_SUCCEED(cuMemAlloc(&ctx->global_failure, sizeof(no_error)));
                 CUDA_SUCCEED(cuMemcpyHtoD(ctx->global_failure, &no_error, sizeof(no_error)));
                 // The +1 is to avoid zero-byte allocations.
                 CUDA_SUCCEED(cuMemAlloc(&ctx->global_failure_args, sizeof(int32_t)*($int:max_failure_args+1)));

                 $stms:(map loadKernel (M.toList kernels))

                 $stms:final_inits
                 $stms:set_sizes

                 init_constants(ctx);
                 // Clear the free list of any deallocations that occurred while initialising constants.
                 CUDA_SUCCEED(cuda_free_all(&ctx->cuda));

                 futhark_context_sync(ctx);

                 return ctx;
               }|])

  GC.publicDef_ "context_free" GC.InitDecl $ \s ->
    ([C.cedecl|void $id:s(struct $id:ctx* ctx);|],
     [C.cedecl|void $id:s(struct $id:ctx* ctx) {
                                 free_constants(ctx);
                                 cuda_cleanup(&ctx->cuda);
                                 free_lock(&ctx->lock);
                                 free(ctx);
                               }|])

  GC.publicDef_ "context_sync" GC.MiscDecl $ \s ->
    ([C.cedecl|int $id:s(struct $id:ctx* ctx);|],
     [C.cedecl|int $id:s(struct $id:ctx* ctx) {
                 CUDA_SUCCEED(cuCtxSynchronize());
                 if (ctx->failure_is_an_option) {
                   // Check for any delayed error.
                   typename int32_t failure_idx;
                   CUDA_SUCCEED(
                     cuMemcpyDtoH(&failure_idx,
                                  ctx->global_failure,
                                  sizeof(int32_t)));
                   ctx->failure_is_an_option = 0;

                   if (failure_idx >= 0) {
                     typename int32_t args[$int:max_failure_args+1];
                     CUDA_SUCCEED(
                       cuMemcpyDtoH(&args,
                                    ctx->global_failure_args,
                                    sizeof(args)));

                     $stm:(failureSwitch failures)

                     return 1;
                   }
                 }
                 return 0;
               }|])


  GC.publicDef_ "context_clear_caches" GC.MiscDecl $ \s ->
    ([C.cedecl|int $id:s(struct $id:ctx* ctx);|],
     [C.cedecl|int $id:s(struct $id:ctx* ctx) {
                         CUDA_SUCCEED(cuda_free_all(&ctx->cuda));
                         return 0;
                       }|])

  where
    loadKernel (name, _) =
      [C.cstm|CUDA_SUCCEED(cuModuleGetFunction(&ctx->$id:name,
                ctx->cuda.module, $string:name));|]
