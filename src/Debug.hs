{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE LambdaCase #-}

-- | Module for debugging Haskell programs. To use, take the functions that
--   you are interested in debugging, e.g.:
--
-- > module QuickSort(quicksort) where
-- > import Data.List
-- >
-- > quicksort :: Ord a => [a] -> [a]
-- > quicksort [] = []
-- > quicksort (x:xs) = quicksort lt ++ [x] ++ quicksort gt
-- >     where (lt, gt) = partition (<= x) xs
--
--   Turn on the @TemplateHaskell@ and @ViewPatterns@ extensions, import "Debug",
--   indent your code and place it under a call to 'debug', e.g.:
--
-- > {-# LANGUAGE TemplateHaskell, ViewPatterns, PartialTypeSignatures #-}
-- > {-# OPTIONS_GHC -Wno-partial-type-signatures #-}
-- > module QuickSort(quicksort) where
-- > import Data.List
-- > import Debug
-- >
-- > debug [d|
-- >    quicksort :: Ord a => [a] -> [a]
-- >    quicksort [] = []
-- >    quicksort (x:xs) = quicksort lt ++ [x] ++ quicksort gt
-- >        where (lt, gt) = partition (<= x) xs
-- >    |]
--
--   We can now run our debugger with:
--
-- > $ ghci QuickSort.hs
-- > GHCi, version 8.2.1: http://www.haskell.org/ghc/  :? for help
-- > [1 of 1] Compiling QuickSort        ( QuickSort.hs, interpreted )
-- > Ok, 1 module loaded.
-- > *QuickSort> quicksort "haskell"
-- > "aehklls"
-- > *QuickSort> debugView
--
--   The final call to 'debugView' starts a web browser to view the recorded information.
--   Alternatively call 'debugSave' to write the web page to a known location.
--
--   For more ways to view the result (e.g. producing JSON) or record traces (without using
--   @TemplateHaskell@) see "Debug.Record".
module Debug(
    -- * Generate trace
    debug,
    -- * View a trace
    debugView, debugSave, debugPrint,
    -- * Clear a trace
    debugClear,
    -- * Exported for tests only
    removeLet
    ) where

import Control.Monad.Extra
import Data.Generics.Uniplate.Data
import Data.List.Extra
import Data.Maybe
import Debug.Record
import Language.Haskell.TH
import Language.Haskell.TH.Syntax


-- | A @TemplateHaskell@ wrapper to convert a normal function into a traced function.
--   For an example see "Debug". Inserts 'funInfo' and 'var' calls.
debug :: Q [Dec] -> Q [Dec]
debug q = do
    missing <- filterM (notM . isExtEnabled) [ViewPatterns, PartialTypeSignatures]
    when (missing /= []) $
        error $ "\ndebug [d| ... |] requires additional extensions:\n" ++
                "{-# LANGUAGE " ++ intercalate ", " (map show missing) ++ " #-}\n"
    decs <- q
    let askSig x = find (\case SigD y _ -> x == y; _ -> False) decs
    mapM (adjustDec askSig) decs


adjustDec :: (Name -> Maybe Dec) -> Dec -> Q Dec
-- try and shove in a "_ =>" if we can, to capture necessary Show instances
adjustDec askSig x@(SigD name (ForallT vars ctxt typ)) = return $
    SigD name $ ForallT vars (delete WildCardT ctxt ++ [WildCardT]) typ
adjustDec askSig (SigD name typ) = adjustDec askSig $ SigD name $ ForallT [] [] typ
adjustDec askSig o@(FunD name clauses@(Clause arity _ _:_)) = do
    runIO $ putStrLn $ "adjustDec (FunD): " ++ (show . ppr) o
    inner <- newName "inner"
    tag <- newName "tag"
    args <- sequence [newName $ "arg" ++ show i | i <- [1 .. length arity]]
    let addTag (Clause ps bod inner) = Clause (VarP tag:ps) bod inner
    let clauses2 = map addTag $ transformBi (adjustPat tag) clauses
    let args2 = [VarE 'var `AppE` VarE tag `AppE` toLitPre "$" a `AppE` VarE a | a <- args]
    let info = ConE 'Function `AppE`
            toLit name `AppE`
            LitE (StringL $ prettyPrint $ maybeToList (askSig name) ++ [o]) `AppE`
            ListE (map (toLitPre "$") args) `AppE`
            LitE (StringL "$result")
    let body2 = VarE 'var `AppE` VarE tag `AppE` LitE (StringL "$result") `AppE` foldl AppE (VarE inner) (VarE tag : args2)
    let body = VarE 'funInfo `AppE` info `AppE` LamE [VarP tag] body2
    afterApps <- transformApps tag clauses2 
    return $ FunD name [Clause (map VarP args) (NormalB body) [FunD inner afterApps]]
adjustDec askSig x = return x

transformApps :: Name -> [Clause] -> Q [Clause]
transformApps tag clauses = sequence $ map (appsFromClause tag) clauses

appsFromClause :: Name -> Clause -> Q Clause
appsFromClause tag cl@(Clause pats body decs) = do
    runIO $ putStrLn $ "appsFromClause: " ++ (show . ppr) cl  
    newBody <- appsFromBody tag body
    return $ Clause pats newBody decs

appsFromBody :: Name -> Body -> Q Body
appsFromBody _ b@(GuardedB _) = return b -- TODO: implement guards
appsFromBody tag (NormalB e) = do 
    runIO $ putStrLn $ "appsFromBody: NormalB e: " ++ (show . ppr) e
    newExp <- appsFromExp tag e
    return (NormalB newExp)

appsFromExp :: Name -> Exp -> Q Exp
appsFromExp tag e@(AppE e1 e2) = do
    runIO $ putStrLn $ "appsFromExp: AppE ("  ++ (show . ppr) e1 ++ ") and (" ++ (show . ppr) e2 ++ ")" 
    newE1 <- appsFromExp tag e1
    newE2 <- appsFromExp tag e2
    runIO $ putStrLn $ "appsFromExp: newE1 after recursion: " ++ (show . ppr) newE1
    adjustedE1 <- adjustApp tag (AppE newE1 newE2)
    return adjustedE1
appsFromExp tag e@(LetE decs exp) = do
    runIO $ putStrLn $ "appsFromExp: LetE decs: (count=" ++ show (length decs) ++ ") and exp: " ++ (show . ppr) exp 
    newDecs <- sequence $ fmap (appsFromDec tag) decs   
    newExp <- appsFromExp tag exp
    return $ LetE newDecs newExp
appsFromExp tag e@(InfixE e1May e2 e3May) = do
    runIO $ putStrLn $ "appsFromExp InfixE: " ++ (show . ppr) e 
    newE1 <- appsFromExpMay tag e1May
    newE2 <- appsFromExp tag e2
    newE3 <- appsFromExpMay tag e3May
    runIO $ putStrLn "skipping infix adjustment.."
    return $ InfixE newE1 newE2 newE3
appsFromExp tag e = do 
    runIO $ putStrLn $ "appsFromExp (not handled): " ++ (show . ppr) e 
    return e  

appsFromExpMay :: Name -> Maybe Exp -> Q (Maybe Exp)
appsFromExpMay tag Nothing = return Nothing
appsFromExpMay tag (Just e) = sequence $ Just $ appsFromExp tag e   

appsFromDec :: Name -> Dec -> Q Dec
appsFromDec tag d@(ValD pat body dec) = do
    runIO $ putStrLn $ "appsFromDec: " ++ (show . ppr) d
    newBody <- appsFromBody tag body
    return $ ValD pat newBody dec
appsFromDec tag d@(FunD name subClauses) = do
    runIO $ putStrLn $ "appsFromDec: <fun name>..not printed" ++ (show . ppr) name
    return d
appsFromDec _ d = do 
    runIO $ putStrLn "appsFromDec - Dec other than FunD..not printed" 
    return d

-- Find the (unqualified) function name to use as the UI display name
expDisplayName :: Exp -> String
expDisplayName e = 
    let name = removeLet $ (show . ppr) e
    in '_' : removeExtraDigits (takeWhileEnd (\c -> c /= '.') ((head . words) name))    

-- discover the function name inside (possibly nested) let expressions
-- transform strings of the form "let (var tag "f" -> f) = f x in f_1" into "f'" 
-- each level of nesting gets a ' (prime) appeneded to the name
removeLet :: String -> String
removeLet str = loop "" str where
   loop suffix s = if "let" `isInfixOf` (fst (word1 s)) 
        then case stripInfix " = " s of
            Just pair -> loop ('\'' : suffix) (snd pair)
            Nothing -> s    -- this shouldn't happen...
        else fst (word1 s) ++ suffix 

--remove possible _n suffix from discovered function names
removeExtraDigits :: String -> String
removeExtraDigits str = case stripInfixEnd "_" str of
    Just s -> fst s
    Nothing -> str

    -- stripInfixEnd :: Eq a => [a] -> [a] -> Maybe ([a], [a]) 

adjustApp :: Name -> Exp -> Q Exp
adjustApp tag (AppE e1 e2) = do
    runIO $ putStrLn $ "AdjustApp: e1 initially: " ++ (show . ppr) e1
    runIO $ putStrLn $ "...displayName: " ++ (expDisplayName e1)
    e1n <- newName $ expDisplayName e1 
    runIO $ putStrLn $ "...after newName..." ++ show e1n
    let viewP = ViewP (VarE 'var `AppE` VarE tag `AppE` toLit e1n) (VarP e1n)
    let result = LetE [ValD viewP (NormalB (AppE e1 e2)) []] (VarE e1n)  
    runIO $ putStrLn $ "...after transform: " ++ (show . ppr) result
    return result
adjustApp _ e = return e

prettyPrint = pprint . transformBi f
    where f (Name x _) = Name x NameS -- avoid nasty qualifications

adjustPat :: Name -> Pat -> Pat
adjustPat tag (VarP x) = ViewP (VarE 'var `AppE` VarE tag `AppE` toLit x) (VarP x)
adjustPat tag x = x

toLit = toLitPre ""
toLitPre pre (Name (OccName x) _) = LitE $ StringL $ pre ++ x
