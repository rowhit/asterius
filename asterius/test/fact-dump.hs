{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

import Asterius.Boot
import Asterius.BuildInfo
import Asterius.Builtins
import Asterius.CodeGen
import Asterius.Internals
import Asterius.Marshal
import Asterius.Resolve
import Asterius.Store
import Bindings.Binaryen.Raw
import Control.Exception
import qualified Data.ByteString as BS
import qualified Data.Map as M
import qualified GhcPlugins as GHC
import Language.Haskell.GHC.Toolkit.Run
import Prelude hiding (IO)
import System.Directory
import System.FilePath
import System.IO hiding (IO)
import System.Process
import Text.Show.Pretty

main :: IO ()
main = do
  boot_args <- getDefaultBootArgs
  let obj_topdir = bootDir boot_args </> "asterius_lib"
  pwd <- getCurrentDirectory
  let test_path = pwd </> "test" </> "fact-dump"
  withCurrentDirectory test_path $ do
    putStrLn "Compiling fact.."
    [(ms_mod, ir)] <- M.toList <$> runHaskell defaultConfig ["fact.hs"]
    case runCodeGen (marshalHaskellIR ir) GHC.unsafeGlobalDynFlags ms_mod of
      Left err -> throwIO err
      Right m -> do
        putStrLn "Dumping IR of fact.."
        writeFile "fact.txt" $ ppShow m
        putStrLn "Chasing Main_main_closure.."
        store' <- decodeFile (obj_topdir </> "asterius_store")
        builtins_opts <- getDefaultBuiltinsOptions
        let store =
              addModule (marshalToModuleSymbol ms_mod) m $
              builtinsStore builtins_opts <> store'
            (maybe_final_m, report) = linkStart store ["main"]
        writeDot "fact.gv" report
        writeFile "fact.link-report.txt" $ ppShow report
        let Just final_m = maybe_final_m
        pPrint final_m
        hFlush stdout
        m_ref <- marshalModule final_m
        print m_ref
        c_BinaryenModulePrint m_ref
        c_BinaryenModuleValidate m_ref >>= print
        m_bin <- serializeModule m_ref
        BS.writeFile "fact.wasm" m_bin
        c_BinaryenModuleDispose m_ref
        callProcess node ["loader.js"]
