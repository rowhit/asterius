{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

import Asterius.Boot
import Asterius.Builtins
import Asterius.CodeGen
import Asterius.Internals
import Asterius.JSFFI
import Asterius.Marshal
import Asterius.Resolve
import Asterius.Store
import Bindings.Binaryen.Raw
import Control.Exception
import Control.Monad
import qualified Data.ByteString as BS
import Data.ByteString.Builder
import qualified Data.HashMap.Strict as HM
import Data.IORef
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import Foreign
import qualified GhcPlugins as GHC
import Language.Haskell.GHC.Toolkit.Run
import Options.Applicative
import Prelude hiding (IO)
import System.Directory
import System.FilePath
import System.IO hiding (IO)
import System.Process
import Text.Show.Pretty

data Task = Task
  { input, outputWasm, outputNode :: FilePath
  , outputLinkReport, outputGraphViz :: Maybe FilePath
  , force, debug, optimize, outputIR, run :: Bool
  }

parseTask :: Parser Task
parseTask =
  (\(i, m_wasm, m_node, m_report, m_gv, fl, dbg, opt, ir, r) ->
     Task
       { input = i
       , outputWasm = fromMaybe (i -<.> "wasm") m_wasm
       , outputNode = fromMaybe (i -<.> "js") m_node
       , outputLinkReport = m_report
       , outputGraphViz = m_gv
       , force = fl
       , debug = dbg
       , optimize = opt
       , outputIR = ir
       , run = r
       }) <$>
  ((,,,,,,,,,) <$> strOption (long "input" <> help "Path of the Main module") <*>
   optional
     (strOption
        (long "output-wasm" <>
         help "Output path of WebAssembly binary, defaults to same path of Main")) <*>
   optional
     (strOption
        (long "output-node" <>
         help
           "Output path of Node.js script, defaults to same path of Main. Must be the same directory as the WebAssembly binary.")) <*>
   optional
     (strOption
        (long "output-link-report" <> help "Output path of linking report")) <*>
   optional
     (strOption
        (long "output-graphviz" <>
         help "Output path of GraphViz file of symbol dependencies")) <*>
   switch
     (long "force" <>
      help "Attempt to link even when non-existent call target exists") <*>
   switch (long "debug" <> help "Enable debug mode in the runtime") <*>
   switch (long "optimize" <> help "Enable binaryen & V8 optimization") <*>
   switch (long "output-ir" <> help "Output Asterius IR of compiled modules") <*>
   switch (long "run" <> help "Run the compiled module with Node.js"))

opts :: ParserInfo Task
opts =
  info
    (parseTask <**> helper)
    (fullDesc <>
     progDesc "Producing a standalone WebAssembly binary from Haskell" <>
     header "ahc-link - Linker for the Asterius compiler")

genNode :: Task -> FFIMarshalState -> LinkReport -> Builder
genNode Task {..} ffi_state LinkReport {..} =
  mconcat $
  [ "\"use strict\";\n"
  , "process.on('unhandledRejection', err => { throw err; });\n"
  , "const fs = require(\"fs\");\n"
  , "let __asterius_wasm_instance = null;\n"
  ] <>
  (if debug
     then [ "const __asterius_func_syms = "
          , string7 $ show $ map fst $ sortOn snd $ HM.toList functionSymbolMap
          , ";\n"
          ]
     else []) <>
  [ "function __asterius_newI64(lo, hi) { return BigInt(lo) | (BigInt(hi) << 32n);  };\n"
  , "let __asterius_jsffi_JSRefs = [];\n"
  , "function __asterius_jsffi_newJSRef(e) { const n = __asterius_jsffi_JSRefs.length; __asterius_jsffi_JSRefs[n] = e; return n; };\n"
  , "WebAssembly.instantiate(fs.readFileSync("
  , string7 $ show $ takeFileName outputWasm
  , "), {Math: Math, jsffi: "
  , generateFFIDict ffi_state
  , ", rts: {printI64: (lo, hi) => console.log(__asterius_newI64(lo, hi))"
  , ", print: console.log"
  , ", panic: e => console.error(\"[ERROR] \" + [\"errGCEnter1\", \"errGCFun\", \"errBarf\", \"errStgGC\", \"errUnreachableBlock\", \"errHeapOverflow\", \"errMegaBlockGroup\", \"errUnimplemented\", \"errAtomics\", \"errSetBaseReg\", \"errBrokenFunction\"][e-1])"
  ] <>
  (if debug
     then [ ", __asterius_memory_trap_trigger: (p_lo, p_hi) => console.error(\"[ERROR] Uninitialized memory trapped at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\"))"
          , ", __asterius_load_i64: (p_lo, p_hi, v_lo, v_hi) => console.log(\"[INFO] Loading i64 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: 0x\" + __asterius_newI64(v_lo,v_hi).toString(16).padStart(8, \"0\"))"
          , ", __asterius_store_i64: (p_lo, p_hi, v_lo, v_hi) => console.log(\"[INFO] Storing i64 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: 0x\" + __asterius_newI64(v_lo,v_hi).toString(16).padStart(8, \"0\"))"
          , ", __asterius_load_i8: (p_lo, p_hi, v) => console.log(\"[INFO] Loading i8 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_store_i8: (p_lo, p_hi, v) => console.log(\"[INFO] Storing i8 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_load_i16: (p_lo, p_hi, v) => console.log(\"[INFO] Loading i16 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_store_i16: (p_lo, p_hi, v) => console.log(\"[INFO] Storing i16 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_load_i32: (p_lo, p_hi, v) => console.log(\"[INFO] Loading i32 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_store_i32: (p_lo, p_hi, v) => console.log(\"[INFO] Storing i32 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_load_f32: (p_lo, p_hi, v) => console.log(\"[INFO] Loading f32 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_store_f32: (p_lo, p_hi, v) => console.log(\"[INFO] Storing f32 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_load_f64: (p_lo, p_hi, v) => console.log(\"[INFO] Loading f64 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_store_f64: (p_lo, p_hi, v) => console.log(\"[INFO] Storing f64 at 0x\" + __asterius_newI64(p_lo, p_hi).toString(16).padStart(8, \"0\") + \", value: \" + v)"
          , ", __asterius_traceCmm: f => console.log(\"[INFO] Entering \" + __asterius_func_syms[f-1] + \", Sp: 0x\" + __asterius_wasm_instance.exports.__asterius_Load_Sp().toString(16).padStart(8, \"0\") + \", SpLim: 0x\" + __asterius_wasm_instance.exports.__asterius_Load_SpLim().toString(16).padStart(8, \"0\") + \", Hp: 0x\" + __asterius_wasm_instance.exports.__asterius_Load_Hp().toString(16).padStart(8, \"0\") + \", HpLim: 0x\" + __asterius_wasm_instance.exports.__asterius_Load_HpLim().toString(16).padStart(8, \"0\"))"
          , ", __asterius_traceCmmBlock: (f, lbl) => console.log(\"[INFO] Branching to \" + __asterius_func_syms[f-1] + \" basic block \" + lbl + \", Sp: 0x\" + __asterius_wasm_instance.exports.__asterius_Load_Sp().toString(16).padStart(8, \"0\") + \", SpLim: 0x\" + __asterius_wasm_instance.exports.__asterius_Load_SpLim().toString(16).padStart(8, \"0\") + \", Hp: 0x\" + __asterius_wasm_instance.exports.__asterius_Load_Hp().toString(16).padStart(8, \"0\") + \", HpLim: 0x\" + __asterius_wasm_instance.exports.__asterius_Load_HpLim().toString(16).padStart(8, \"0\"))"
          , ", __asterius_traceCmmSetLocal: (f, i, lo, hi) => console.log(\"[INFO] In \" + __asterius_func_syms[f-1] + \", Setting local register \" + i + \" to 0x\" + __asterius_newI64(lo, hi).toString(16).padStart(8, \"0\"))"
          ]
     else []) <>
  [ "}}).then(r => {__asterius_wasm_instance = r.instance; __asterius_wasm_instance.exports.main();});\n"
  ]

main :: IO ()
main = do
  task@Task {..} <- execParser opts
  (boot_store, boot_pkgdb) <-
    do (store_path, boot_pkgdb) <-
         do boot_args <- getDefaultBootArgs
            let boot_lib = bootDir boot_args </> "asterius_lib"
            pure (boot_lib </> "asterius_store", boot_lib </> "package.conf.d")
       putStrLn $ "[INFO] Loading boot library store from " <> show store_path
       store <- decodeFile store_path
       pure (store, boot_pkgdb)
  putStrLn "[INFO] Populating the store with builtin routines"
  def_builtins_opts <- getDefaultBuiltinsOptions
  let builtins_opts = def_builtins_opts {tracing = debug}
      !orig_store = builtinsStore builtins_opts <> boot_store
  putStrLn $ "[INFO] Compiling " <> input <> " to Cmm"
  (c, get_ffi_state) <- addFFIProcessor mempty
  mod_ir_map <-
    runHaskell
      defaultConfig
        { ghcFlags =
            [ "-Wall"
            , "-O2"
            , "-clear-package-db"
            , "-global-package-db"
            , "-package-db"
            , boot_pkgdb
            , "-hide-all-packages"
            , "-package"
            , "ghc-prim"
            , "-package"
            , "integer-simple"
            , "-package"
            , "base"
            , "-package"
            , "array"
            , "-package"
            , "deepseq"
            ]
        , compiler = c
        }
      [input]
  ffi_state <- get_ffi_state
  putStrLn "[INFO] Marshalling from Cmm to WebAssembly"
  final_store_ref <- newIORef orig_store
  M.foldlWithKey'
    (\act ms_mod ir ->
       case runCodeGen
              (marshalHaskellIR ir)
              (dflags builtins_opts)
              ms_mod
              ffi_state of
         Left err -> throwIO err
         Right m -> do
           let mod_str = GHC.moduleNameString $ GHC.moduleName ms_mod
           putStrLn $
             "[INFO] Marshalling " <> show mod_str <> " from Cmm to WebAssembly"
           modifyIORef' final_store_ref $
             addModule (marshalToModuleSymbol ms_mod) m
           when outputIR $ do
             let p = takeDirectory input </> mod_str <.> "txt"
             putStrLn $
               "[INFO] Writing pretty-printed IR of " <> mod_str <> " to " <> p
             writeFile p $ ppShow m
           act)
    (pure ())
    mod_ir_map
  final_store <- readIORef final_store_ref
  putStrLn "[INFO] Attempting to link into a standalone WebAssembly module"
  let (!m_final_m, !report) =
        linkStart force debug ffi_state final_store $
        if debug
          then [ "main"
               , "__asterius_Load_Sp"
               , "__asterius_Load_SpLim"
               , "__asterius_Load_Hp"
               , "__asterius_Load_HpLim"
               ]
          else ["main"]
  maybe
    (pure ())
    (\p -> do
       putStrLn $ "[INFO] Writing linking report to " <> show p
       writeFile p $ ppShow report)
    outputLinkReport
  maybe
    (pure ())
    (\p -> do
       putStrLn $
         "[INFO] Writing GraphViz file of symbol dependencies to " <> show p
       writeDot p report)
    outputGraphViz
  maybe
    (fail "[ERROR] Linking failed")
    (\final_m -> do
       when outputIR $ do
         let p = input -<.> "txt"
         putStrLn $ "[INFO] Writing linked IR to " <> show p
         writeFile p $ show final_m
       putStrLn "[INFO] Invoking binaryen to marshal the WebAssembly module"
       m_ref <- withPool $ \pool -> marshalModule pool final_m
       putStrLn "[INFO] Validating the WebAssembly module"
       pass_validation <- c_BinaryenModuleValidate m_ref
       when (pass_validation /= 1) $ fail "[ERROR] Validation failed"
       when optimize $ do
         putStrLn "[INFO] Invoking binaryen optimizer"
         c_BinaryenModuleOptimize m_ref
       putStrLn "[INFO] Serializing the WebAssembly module to the binary form"
       !m_bin <- serializeModule m_ref
       putStrLn $ "[INFO] Writing WebAssembly binary to " <> show outputWasm
       BS.writeFile outputWasm m_bin
       putStrLn $ "[INFO] Writing Node.js script to " <> show outputNode
       h <- openBinaryFile outputNode WriteMode
       hPutBuilder h $ genNode task ffi_state report
       hClose h
       when run $ do
         putStrLn $ "[INFO] Running " <> outputNode
         withCurrentDirectory (takeDirectory outputWasm) $
           callProcess "node" $
           ["--wasm-opt" | optimize] <>
           ["--harmony-bigint", takeFileName outputNode])
    m_final_m
