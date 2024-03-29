  -----------------------------------------------------------------------------
-- Copyright 2012 Microsoft Corporation.
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the file "license.txt" at the root of this distribution.
-----------------------------------------------------------------------------
{-    System F-like core language. 
-}
-----------------------------------------------------------------------------

module Core.Core ( -- Data structures
                     Core(..)
                   , Imports, Import(..)
                   , Externals, External(..), externalVis
                   , FixDefs, FixDef(..)
                   , TypeDefGroups, TypeDefGroup(..), TypeDefs, TypeDef(..)
                   , DefGroups, DefGroup(..), Defs, Def(..)
                   , Expr(..), Lit(..)
                   , Branch(..), Guard(..), Pattern(..)
                   , TName(..), getName, typeDefName
                   , showTName
                   , flattenDefGroups
                   , extractSignatures
                   
                     -- Term substitution
                   , (|~>)
                     -- Core term builders
                   , defIsVal
                   , defTName
                   , addTypeLambdas, addTypeApps, addLambdas, addApps, addLambda
                   , makeLet
                   , addNonRec, addCoreDef, coreNull
                   , freshName                   
                   , typeOf
                   , HasExpVar, fv, bv
                   , isExprTrue,  exprTrue

                   , isExprFalse, exprFalse
                   , Visibility(..), Fixity(..), Assoc(..)
                   , coreName
                   , tnamesList
                   , TNames
                   , splitFun
                   , isTopLevel
                   , isTotal
                   -- * Data representation
                   , DataRepr(..), ConRepr(..)
                   , isConSingleton
                   , isConNormal
                   , getDataRepr
                   , VarInfo(..)

                   -- * Canonical names
                   , canonicalName, nonCanonicalName, canonicalSplit
                   ) where

import Data.Char( isDigit )
import qualified Data.Set as S
import Data.Maybe
import Common.Name
import Common.Range
import Common.Failure
import Common.Unique
import Common.NamePrim( nameTrue, nameFalse, nameTpBool )
import Common.Syntax

import Type.Type
import Type.Pretty ()
import Type.TypeVar

isExprTrue (Con tname _)  = (getName tname == nameTrue)
isExprTrue _              = False

isExprFalse (Con tname _)  = (getName tname == nameFalse)
isExprFalse _              = False

exprTrue   = Con (TName nameTrue         typeBool) (ConEnum nameTpBool 2)
exprFalse  = Con (TName nameFalse        typeBool) (ConEnum nameTpBool 1)

{--------------------------------------------------------------------------
  Top-level structure 
--------------------------------------------------------------------------}

data Core = Core{ coreProgName :: Name 
                , coreProgImports :: Imports 
                , coreProgFixDefs :: FixDefs 
                , coreProgTypeDefs :: TypeDefGroups 
                , coreProgDefs :: DefGroups 
                , coreProgExternals :: Externals
                , coreProgDoc :: String
                }


type FixDefs
  = [FixDef]

data FixDef
  = FixDef Name Fixity 


coreName :: Core -> Name
coreName (Core name _ _ _ _ _ _) = name

{---------------------------------------------------------------
  Imports
---------------------------------------------------------------}

-- | Core imports
type Imports = [Import]

data Import  = Import{ importName :: Name 
                     , importPackage :: String
                     , importVis  :: Visibility
                     , importModDoc :: String
                     }

{--------------------------------------------------------------------------
  Externals   
--------------------------------------------------------------------------}

type Externals = [External]

data External = External{ externalName :: Name 
                        , externalType :: Scheme 
                        , externalFormat :: [(Target,String)]
                        , externalVis' :: Visibility 
                        , externalRange :: Range
                        , externalDoc :: String
                        }
              | ExternalInclude{ externalInclude :: [(Target,String)]
                               , externalRange :: Range } 
              | ExternalImport { externalImport :: [(Target,(Name,String))]
                               , externalRange :: Range } 

externalVis :: External -> Visibility
externalVis (External{ externalVis' = vis }) = vis
externalVis _ = Private

{--------------------------------------------------------------------------
  Type definitions 
--------------------------------------------------------------------------}

type TypeDefGroups = [TypeDefGroup]

data TypeDefGroup = TypeDefGroup TypeDefs

type TypeDefs = [TypeDef]

-- | A type definition
data TypeDef =
    Synonym{ typeDefSynInfo :: SynInfo, typeDefVis ::  Visibility }             -- ^ name, synonym info, and the visibility
  | Data{ typeDefDataInfo :: DataInfo, typeDefVis ::  Visibility, typeDefConViss :: [Visibility] }  -- ^ name, info, visibility, and the visibilities of the constructors

typeDefName (Synonym info _) = synInfoName info
typeDefName (Data info _ _)  = dataInfoName info

{--------------------------------------------------------------------------
  Data representation
--------------------------------------------------------------------------}
data DataRepr = DataEnum | DataSingleStruct | DataSingle | DataAsList | DataSingleNormal | DataStruct | DataNormal 
              deriving (Eq,Ord,Show)

data ConRepr  = ConEnum{ conTypeName :: Name, conTag :: Int }                     -- part of enumeration (none has fields)
              | ConSingleton{ conTypeName :: Name, conTag :: Int }                -- the only constructor without fields
              | ConSingle{ conTypeName :: Name, conTag :: Int }                   -- there is only one constructor (and this is it)
              | ConStruct{ conTypeName :: Name, conTag :: Int }                   -- constructor as value type
              | ConAsCons{ conTypeName :: Name, conAsNil :: Name, conTag :: Int } -- constructor is the cons node of a list-like datatype  (may have one or more fields)
              | ConNormal{ conTypeName :: Name, conTag :: Int }                   -- a regular constructor
              deriving (Eq,Ord,Show)

isConSingleton (ConSingleton _ _) = True
isConSingleton _ = False

isConNormal (ConNormal _ _) = True
isConNormal _  = False

getDataRepr :: Int -> DataInfo -> (DataRepr,[ConRepr])
getDataRepr maxStructFields info
  = let typeName  = dataInfoName info
        conInfos = dataInfoConstrs info
        conTags  = [0..length conInfos - 1]
        singletons =  filter (\con -> null (conInfoParams con)) conInfos
        (dataRepr,conReprFuns) = 
         if (null (dataInfoParams info) && all (\con -> null (conInfoParams con) && null (conInfoExists con)) conInfos)
          then (DataEnum,map (const (ConEnum typeName)) conInfos)
         else if (length conInfos == 1)
          then let conInfo = head conInfos
               in (if (length (conInfoParams conInfo) <= maxStructFields && null singletons && not (dataInfoIsRec info)) 
                    then DataSingleStruct 
                    else DataSingle
                  ,[if length singletons == 1 then ConSingleton typeName else ConSingle typeName])
         else if (length singletons == length conInfos-1 && length (concatMap conInfoParams conInfos) <= maxStructFields && not (dataInfoIsRec info))
          then (DataStruct, map (\_ -> ConStruct typeName) conInfos )
         else if (length conInfos == 2 && length singletons == 1)
          then (DataAsList
               ,map (\con -> if (null (conInfoParams con)) then ConSingleton typeName
                              else ConAsCons typeName (conInfoName (head singletons))) conInfos)
         else (if (length singletons == length conInfos -1 || null conInfos) then DataSingleNormal else DataNormal 
               ,map (\con -> {- if null (conInfoParams con) then ConSingleton typeName else -} 
                              ConNormal typeName) conInfos 
               )
      in (dataRepr, [conReprFun tag | (conReprFun,tag) <- zip conReprFuns [1..]])


{--------------------------------------------------------------------------
  Definition groups
--------------------------------------------------------------------------}

type DefGroups = [DefGroup]

data DefGroup =
    DefRec Defs 
  | DefNonRec Def

type Defs = [Def]

flattenDefGroups :: [DefGroup] -> [Def]
flattenDefGroups defGroups
  = concatMap (\defg -> case defg of { DefRec defs -> defs; DefNonRec def -> [def]}) defGroups

-- | A value definition
data Def = Def{ defName  :: Name 
              , defType  :: Scheme 
              , defExpr  :: Expr 
              , defVis   :: Visibility
              , defSort  :: DefSort
              , defNameRange :: Range
              , defDoc  :: String
              }

defIsVal :: Def -> Bool
defIsVal def
  = DefFun /= defSort def


canonicalSep = '.'

canonicalName :: Int -> Name -> Name
canonicalName n name
  = if (n/=0) then postpend ([canonicalSep] ++ show n) name else name

nonCanonicalName :: Name -> Name
nonCanonicalName name
  = fst (canonicalSplit name)

canonicalSplit :: Name -> (Name,String)
canonicalSplit name
  = case (span isDigit (reverse (nameId name))) of
      (postfix, c:rest) | c == canonicalSep && not (null postfix) -> (newQualified (nameModule name) (reverse rest), c:reverse postfix)
      _        -> (name,"")


{--------------------------------------------------------------------------
  Expressions 

  Since this is System-F, all binding sites are annotated with their type.
--------------------------------------------------------------------------}

data Expr =
  -- Core lambda calculus
    Lam [TName] Expr  
  | Var{ varName :: TName, varInfo :: VarInfo }  -- ^ typed name and possible typeArity/parameter arity tuple for top-level functions
  | App Expr [Expr]
  -- Type (universal) abstraction/application
  | TypeLam [TypeVar] Expr
  | TypeApp Expr [Type]
  -- Literals, constants and labels
  | Con{ conName :: TName, conRepr ::  ConRepr  }          -- ^ typed name and its representation
  | Lit Lit 
  -- Let
  | Let DefGroups Expr
  -- Case expressions
  | Case{ caseExprs :: [Expr], caseBranches :: [Branch] }

data TName = TName Name Type

getName (TName name _) = name

showTName (TName name tp)
    = show name -- ++ ": " ++ minCanonical tp


defTName :: Def -> TName
defTName def
  = TName (defName def) (defType def)

data VarInfo
  = InfoNone
  | InfoArity Int Int -- #Type parameters, #parameters
  | InfoExternal [(Target,String)]

data Branch = Branch { branchPatterns :: [Pattern]
                     , branchGuards   :: [Guard] 
                     } 

data Guard  = Guard { guardTest :: Expr
                    , guardExpr :: Expr
                    }

data Pattern
  = PatCon{ patConName :: TName, patConPatterns:: [Pattern], patConRepr :: ConRepr, patTypeArgs :: [Type], patConInfo :: ConInfo }
  | PatVar{ patName :: TName, patPattern :: Pattern }
  | PatWild

data Lit = 
    LitInt    Integer
  | LitFloat  Double
  | LitChar   Char
  | LitString String
  deriving (Eq)

-- | a core expression is total if it cannot cause non-total evaluation
isTotal:: Expr -> Bool
isTotal expr
  = case expr of
      Lam _ _ -> True
      Var _ _ -> True
      TypeLam _ _ -> True  
      TypeApp e _ -> isTotal e
      Con _ _ -> True
      Lit _   -> True
      App f args -> case typeOf f of
                      TFun pars eff res -> (length args == length pars && eff == typeTotal && all isTotal args)
                      _                 -> False
      _       -> False  -- todo: a let could be total

{--------------------------------------------------------------------------
  Type variables inside core expressions 
--------------------------------------------------------------------------}


instance HasTypeVar DefGroup where
  sub `substitute` defGroup
    = case defGroup of
        DefRec defs   -> DefRec (sub `substitute` defs)
        DefNonRec def -> DefNonRec (sub `substitute` def)

  ftv defGroup
    = case defGroup of  
        DefRec defs   -> ftv defs 
        DefNonRec def -> ftv def 

  btv defGroup
    = case defGroup of
        DefRec defs   -> btv defs 
        DefNonRec def -> btv def


instance HasTypeVar Def where
  sub `substitute` (Def name scheme expr vis isVal nameRng doc)
    = Def name (sub `substitute` scheme) (sub `substitute` expr) vis isVal nameRng doc

  ftv (Def name scheme expr vis isVal  nameRng doc)
    = ftv scheme `tvsUnion` ftv expr

  btv (Def name scheme expr vis isVal nameRng doc)
    = btv scheme `tvsUnion` btv expr

instance HasTypeVar Expr where
  sub `substitute` expr 
    = case expr of
        Lam tnames expr   -> Lam (sub `substitute` tnames) (sub `substitute` expr)
        Var tname info    -> Var (sub `substitute` tname) info
        App f args        -> App (sub `substitute` f) (sub `substitute` args)
        TypeLam tvs expr  -> let sub' = subRemove tvs sub 
                              in TypeLam tvs (sub' |-> expr)
        TypeApp expr tps   -> TypeApp (sub `substitute` expr) (sub `substitute` tps) 
        Con tname repr     -> Con (sub `substitute` tname) repr
        Lit lit            -> Lit lit
        Let defGroups expr -> Let (sub `substitute` defGroups) (sub `substitute` expr)
        Case exprs branches -> Case (sub `substitute` exprs) (sub `substitute` branches)  

  ftv expr
    = case expr of
        Lam tname expr     -> ftv tname `tvsUnion` ftv expr
        Var tname info     -> ftv tname
        App a b            -> ftv a `tvsUnion` ftv b
        TypeLam tvs expr   -> tvsRemove tvs (ftv expr) 
        TypeApp expr tp    -> ftv expr `tvsUnion` ftv tp 
        Con tname repr     -> ftv tname
        Lit lit            -> tvsEmpty
        Let defGroups expr -> ftv defGroups `tvsUnion` ftv expr
        Case exprs branches -> ftv exprs `tvsUnion` ftv branches 

  btv expr
    = case expr of
        Lam tname  expr    -> btv tname `tvsUnion` btv expr
        Var tname info     -> btv tname
        App a b            -> btv a `tvsUnion` btv b
        TypeLam tvs expr   -> tvsInsertAll tvs (btv expr)  
        TypeApp expr tp    -> btv expr `tvsUnion` btv tp 
        Con tname repr     -> btv tname 
        Lit lit            -> tvsEmpty
        Let defGroups expr -> btv defGroups `tvsUnion` btv expr
        Case exprs branches -> btv exprs `tvsUnion` btv branches


instance HasTypeVar Branch where
  sub `substitute` (Branch patterns guards)
    = let sub' = subRemove (tvsList (btv patterns)) sub 
      in Branch (map ((sub `substitute`)) patterns) (map (sub' `substitute`) guards)
 
  ftv (Branch patterns guards)
    = ftv patterns `tvsUnion` (tvsDiff (ftv guards) (btv patterns))

  btv (Branch patterns guards)
    = btv patterns `tvsUnion` btv guards


instance HasTypeVar Guard where
  sub `substitute` (Guard test expr)
    = Guard (sub `substitute` test) (sub `substitute` expr)
  ftv (Guard test expr)
    = ftv test `tvsUnion` ftv expr
  btv (Guard test expr)
    = btv test `tvsUnion` btv expr

instance HasTypeVar Pattern where
  sub `substitute` pat
    = case pat of
        PatVar tname pat   -> PatVar (sub `substitute` tname) (sub `substitute` pat)
        PatCon tname args repr tps info -> PatCon (sub `substitute` tname) (sub `substitute` args) repr (sub `substitute` tps) info
        PatWild           -> PatWild

 
  ftv pat
    = case pat of
        PatVar tname pat    -> tvsUnion (ftv tname) (ftv pat)
        PatCon tname args _ targs _ -> tvsUnions [ftv tname,ftv args,ftv targs]
        PatWild             -> tvsEmpty

  btv pat
    = case pat of
        PatVar tname pat           -> tvsUnion (btv tname) (btv pat)
        PatCon tname args _ targs _  -> tvsUnions [btv tname,btv args,btv targs]
        PatWild                 -> tvsEmpty


instance HasTypeVar TName where
  sub `substitute` (TName name tp)
    = TName name (sub `substitute` tp)
  ftv (TName name tp)
    = ftv tp
  btv (TName name tp)
    = btv tp


---------------------------------------------------------------------------
-- 
---------------------------------------------------------------------------
isTopLevel :: Def -> Bool
isTopLevel (Def name tp expr vis isVal nameRng doc)
  = let freeVar = filter (\(nm) -> not (isQualified nm) && nm /= unqualify name) (map getName (tnamesList (fv expr)))
        freeTVar = ftv expr
        yes = (null freeVar && tvsIsEmpty freeTVar)
    in -- trace ("isTopLevel " ++ show name ++ ": " ++ show (yes,freeVar,tvsList freeTVar)) $ 
        yes

         
type TNames = S.Set TName

tnamesList :: TNames -> [TName]
tnamesList tns
  = S.elems tns

instance Eq TName where
  (TName name1 tp1) == (TName name2 tp2)  = (name1 == name2) --  && matchType tp1 tp2)

instance Ord TName where
  compare (TName name1 tp1) (TName name2 tp2)  
    = compare name1 name2 
       {- EQ  -> compare (minCanonical tp1) (minCanonical tp2)
        lgt -> lgt -}




instance Show TName where
  show tname 
    = show (getName tname)


class HasExpVar a where
  -- Return free variables 
  fv :: a -> TNames

  -- Top level bound variables
  bv :: a -> TNames
  

instance HasExpVar a => HasExpVar [a] where
  fv xs
    = S.unions (map fv xs)

  bv xs
    = S.unions (map bv xs)


instance HasExpVar DefGroup where
  fv defGroup
   = case defGroup of
      DefRec defs   -> fv defs `S.difference` bv defs
      DefNonRec def -> fv def

  bv defGroup
   = case defGroup of
      DefRec defs   -> bv defs 
      DefNonRec def -> bv def

instance HasExpVar Def where
  fv (Def name tp expr vis isVal nameRng doc) = fv expr
  bv (Def name tp expr vis isVal nameRng doc) = S.singleton (TName name tp)

instance HasExpVar Expr where
  -- extract free variables from an expression
  fv (Lam tnames expr)    = foldr S.delete (fv expr) tnames 
  fv v@(Var tname info)   = S.singleton tname
  fv (App e1 e2)          = fv e1 `S.union` fv e2
  fv (TypeLam tyvar expr) = fv expr
  fv (TypeApp expr ty)    = fv expr
  fv (Con tname repr)     = S.empty
  fv (Lit i)              = S.empty
  fv (Let dfgrps expr)    = fv dfgrps `S.union` (fv expr `S.difference` bv dfgrps)
  fv (Case exprs bs)      = fv exprs `S.union` fv bs
  
  bv exp                  = failure "Backend.CSharp.FromCore.bv on expr"

instance HasExpVar Branch where
  fv (Branch patterns guards) = fv guards `S.difference` bv patterns
  bv (Branch patterns guards) = bv patterns `S.union` bv guards

instance HasExpVar Guard where
  fv (Guard test expr) = fv test `S.union` fv expr
  bv (Guard test expr) = bv test `S.union` bv expr

instance HasExpVar Pattern where
  fv pat
    = S.empty
  bv pat
    = case pat of 
        PatCon tname args _ _  _ -> bv args
        PatVar tname pat         -> S.union (S.singleton tname) (bv pat)
        PatWild                  -> S.empty

{--------------------------------------------------------------------------
  Term-substitutions   
--------------------------------------------------------------------------}

class HasExprVar a where
  (|~>) :: [(TName, Expr)] -> a -> a

instance HasExprVar a => HasExprVar [a] where
  sub |~> xs
    = map (sub |~>) xs

instance (HasExprVar a, HasExprVar b, HasExprVar c) => HasExprVar (a,b,c) where
  sub |~> (x,y,z)
    = (sub |~> x, sub |~> y, sub |~> z)

instance HasExprVar DefGroup where
  sub |~> defGroup 
    = case defGroup of
        DefRec    defs -> DefRec (sub |~> defs)
        DefNonRec def  -> DefNonRec (sub |~> def)


instance HasExprVar Def where
  sub |~> (Def name scheme expr vis isVal nameRng doc) 
    = assertion "Core.HasExprVar.Def.|~>" (TName name scheme `notIn` sub) $
      Def name scheme (sub |~> expr) vis isVal nameRng doc

instance HasExprVar Expr where
  sub |~> expr = 
    case expr of
      Lam tnames  expr    -> assertion "Core.HasExprVar.Expr.|~>" (all (\tname -> tname `notIn` sub) tnames) $ 
                              Lam tnames (sub |~> expr)
      Var tname info       -> fromMaybe expr (lookup tname sub)
      App e1 e2            -> App (sub |~> e1) (sub |~> e2)
      TypeLam typeVar exp  -> assertion ("Core.HasExprVar.Expr.|~>.TypeLam") (all (\tv -> not (tvsMember tv (ftv (map snd sub)))) typeVar) $
                               TypeLam typeVar (sub |~> exp)
      TypeApp expr tp      -> TypeApp (sub |~> expr) tp
      Con tname repr       -> expr
      Lit lit              -> expr
      Let defGroups expr   -> Let (sub |~> defGroups) (sub |~> expr)
      Case expr branches   -> Case (sub |~> expr) (sub |~> branches)  


instance HasExprVar Branch where
  sub |~> (Branch patterns guards) 
    = let bvpat = bv patterns
          sub' = [(name,expr) | (name,expr) <- sub, not (S.member (name ) bvpat)]
      in Branch patterns (map (sub' |~>) guards)

instance HasExprVar Guard where
  sub |~> (Guard test expr)
    = Guard (sub |~> test) (sub |~> expr)


notIn :: TName -> [(TName, Expr)] -> Bool
notIn name subst = not (name `elem` map fst subst)

{--------------------------------------------------------------------------
  Auxiliary functions to build Core terms 
--------------------------------------------------------------------------}

-- | Create a let expression
makeLet :: [DefGroup] -> Expr -> Expr
makeLet [] expr = expr
makeLet defs expr = Let defs expr

-- | Add a value application
addApps :: [Expr] -> (Expr -> Expr)
addApps [] e             = e
addApps es (App e args)  = App e (args ++ es)
addApps es e             = App e es

-- | Add kind and type application
addTypeApps :: [TypeVar] -> (Expr -> Expr)
addTypeApps [] e                = e
addTypeApps ts (TypeApp e args) = TypeApp e (args ++ [TVar t | t <- ts])
addTypeApps ts e                = TypeApp e [TVar t | t <- ts]

-- | Add kind and type lambdas 
addTypeLambdas :: [TypeVar] -> (Expr -> Expr)
addTypeLambdas []   e              = e
addTypeLambdas pars (TypeLam ps e) = TypeLam (pars ++ ps) e
addTypeLambdas pars e              = TypeLam pars e

-- | Add term lambdas
addLambdas :: [(Name, Type)] -> (Expr -> Expr)
addLambdas [] e              = e
addLambdas pars (Lam ps e)   = Lam ([TName x tp | (x,tp) <- pars] ++ ps) e
addLambdas pars e            = Lam [TName x tp | (x,tp) <- pars] e

-- | Add term lambdas
addLambda :: [TName] -> (Expr -> Expr)
addLambda [] e              = e
addLambda pars (Lam ps e)   = Lam (pars ++ ps) e
addLambda pars e            = Lam pars e


-- | Bind a variable inside a term
addNonRec :: Name -> Type -> Expr -> (Expr -> Expr)
addNonRec x tp e e' = Let [DefNonRec (Def x tp e Private (if isValueExpr e then DefVal else DefFun) rangeNull "")] e'

-- | Is an expression a value or a function
isValueExpr :: Expr -> Bool
isValueExpr (TypeLam tpars (Lam pars e))   = False
isValueExpr (Lam pars e)                   = False
isValueExpr _                              = True

-- | Add a definition 
addCoreDef :: Core -> Def -> Core
addCoreDef (Core name imports fixdefs typeDefGroups (defGroups) externals doc) def
  = Core name imports fixdefs typeDefGroups (defGroups ++ [DefNonRec def]) externals doc

-- | Empty Core program
coreNull :: Name -> Core
coreNull name = Core name [] [] [] [] [] ""

-- | Create a fresh variable name with a particular prefix
freshName :: HasUnique m => String -> m Name
freshName prefix 
  = do id <- unique 
       return (newName $ prefix ++ "." ++ show id)


---------------------------------------------------------------------------
-- type of a core term
---------------------------------------------------------------------------
class HasType a where
  typeOf :: a -> Type

instance HasType Def where
  typeOf def  = defType def

instance HasType TName where
  typeOf (TName _ tp)   = tp

instance HasType Expr where
  -- Lambda abstraction
  typeOf (Lam pars expr)
    = typeFun [(name,tp) | TName name tp <- pars] typeTotal (typeOf expr) -- TODO: effect is wrong

  -- Variables
  typeOf (Var tname info)
    = typeOf tname

  -- Constants 
  typeOf (Con tname repr)
    = typeOf tname

  -- Application
  typeOf (App fun args)
    = snd (splitFun (typeOf fun))

  -- Type lambdas
  typeOf (TypeLam xs expr)
    = TForall xs [] (typeOf expr)

  -- Type application
  typeOf (TypeApp expr [])
    = typeOf expr

  typeOf (TypeApp expr tps)
    = let (tvs,tp1) = splitTForall (typeOf expr)
      in -- assertion "Core.Core.typeOf.TypeApp" (getKind a == getKind tp) $
         subNew (zip tvs tps) |-> tp1

  -- Literals
  typeOf (Lit l) 
    = case l of
        LitInt _    -> typeInt
        LitFloat _  -> typeFloat
        LitChar _   -> typeChar
        LitString _ -> typeString

  -- Let
  typeOf (Let defGroups expr) 
    = typeOf expr 

  -- Case
  typeOf (Case exprs branches)
    = typeOf (head branches)

{--------------------------------------------------------------------------
  Type of a branch 
--------------------------------------------------------------------------}
instance HasType Branch where
  typeOf (Branch _ guards) 
    = case guards of
        (guard:_) -> typeOf guard
        _         -> failure "Core.Core.HasType Branch: branch without any guards" 

instance HasType Guard where
  typeOf (Guard _ expr)
    = typeOf expr


{--------------------------------------------------------------------------
  Extract types 
--------------------------------------------------------------------------}
extractSignatures :: Core -> [Type]
extractSignatures core
  = let tps = concat [
                extractExternals (coreProgExternals core),
                extractDefs (coreProgDefs core)
              ]
    in -- trace ("extract signatures: " ++ show (map pretty tps)) $
       tps
  where
    extractExternals = concatMap extractExternal
    extractExternal ext@(External{ externalType = tp }) | externalVis ext == Public = [tp]
    extractExternal _ = []

    extractDefs = map defType . filter (\d -> defVis d == Public) . flattenDefGroups 


{--------------------------------------------------------------------------
  Decompose types 
--------------------------------------------------------------------------}

splitFun :: Type -> ([(Name,Type)], Type)
-- splitFun (TApp (TApp con arg) res) | con == typeArrow = (arg, res)
splitFun tp
  = case expandSyn tp of
      TFun args eff res -> (args,res)
      _ -> failure ("Core.Core.splitFun: Expected function: " ++ show tp) 
  
splitTForall :: Type -> ([TypeVar], Type)
splitTForall tp
  = case expandSyn tp of
      (TForall tvs _ tp) -> (tvs, tp) -- TODO what about the rest of the variables and preds?
      _ ->  failure ("Core.Core.splitTForall: Expected forall" ++ show tp)
