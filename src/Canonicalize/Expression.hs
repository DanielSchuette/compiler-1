{-# OPTIONS_GHC -Wall #-}
module Canonicalize.Expression
  ( canonicalize
  )
  where


import Control.Applicative (liftA2)
import qualified Data.Graph as Graph
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import qualified AST.Expression.Canonical as Can
import qualified AST.Expression.Valid as Valid
import qualified Canonicalize.Environment as Env
import qualified Canonicalize.Environment.Dups as Dups
import qualified Canonicalize.Pattern as Pattern
import qualified Canonicalize.Type as Type
import qualified Elm.Name as N
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as Error
import qualified Reporting.Region as R
import qualified Reporting.Result as Result
import qualified Reporting.Warning as Warning



-- RESULTS


type Result i a =
  Result.Result i Warning.Warning Error.Error a


type FreeLocals =
  Set.Set N.Name



-- EXPRESSIONS


canonicalize :: Env.Env -> Valid.Expr -> Result FreeLocals Can.Expr
canonicalize env (A.A region expression) =
  A.A region <$>
  case expression of
    Valid.Literal lit ->
      Result.ok (Can.Literal lit)

    Valid.Var maybePrefix name ->
      Env.findVar region env maybePrefix name

    Valid.List exprs ->
      Can.List <$> traverse (canonicalize env) exprs

    Valid.Op name ->
      do  (Env.Binop home func _ _) <- Env.findBinop region env name
          return (Can.VarOperator name home func)

    Valid.Negate expr ->
      Can.Negate <$> canonicalize env expr

    Valid.Binops ops final ->
      error "TODO"

    Valid.Lambda args body ->
      addLocals $
      do  cargs@(Can.Args _ destructors) <- Pattern.canonicalizeArgs env args
          newEnv <- Env.addLocals destructors env
          removeLocals destructors $
            Can.Lambda cargs <$> canonicalize newEnv body

    Valid.Call func args ->
      Can.Call
        <$> canonicalize env func
        <*> traverse (canonicalize env) args

    Valid.If branches finally ->
      Can.If
        <$> traverse (canonicalizeBranch env) branches
        <*> canonicalize env finally

    Valid.Let defs expr ->
      A.drop <$> canonicalizeLet region env defs expr

    Valid.Case expr cases ->
      error "TODO"

    Valid.Accessor field ->
      Result.ok $ Can.Accessor field

    Valid.Access record field ->
      Can.Access
        <$> canonicalize env record
        <*> Result.ok field

    Valid.Update (A.A reg name) fields ->
      do  fieldDict <- Result.untracked $ Dups.checkFields fields
          name_ <- Env.findVar reg env Nothing name
          Can.Update (A.A reg name_)
            <$> traverse (canonicalize env) fieldDict

    Valid.Record fields ->
      do  fieldDict <- Result.untracked $ Dups.checkFields fields
          Can.Record <$> traverse (canonicalize env) fieldDict

    Valid.Unit ->
      Result.ok Can.Unit

    Valid.Tuple a b cs ->
      Can.Tuple
        <$> canonicalize env a
        <*> canonicalize env b
        <*> canonicalizeTupleExtras region env cs

    Valid.GLShader uid src tipe ->
        Result.ok (Can.GLShader uid src tipe)



-- CANONICALIZE TUPLE EXTRAS


canonicalizeTupleExtras :: R.Region -> Env.Env -> [Valid.Expr] -> Result FreeLocals (Maybe Can.Expr)
canonicalizeTupleExtras region env extras =
  case extras of
    [] ->
      Result.ok Nothing

    [three] ->
      Just <$> canonicalize env three

    _ : others ->
      let (A.A r1 _, A.A r2 _) = (head others, last others) in
      Result.throw region (Error.TupleLargerThanThree (R.merge r1 r2))



-- CANONICALIZE IF BRANCH


canonicalizeBranch :: Env.Env -> (Valid.Expr, Valid.Expr) -> Result FreeLocals (Can.Expr, Can.Expr)
canonicalizeBranch env (condition, branch) =
  liftA2 (,) (canonicalize env condition) (canonicalize env branch)



-- CANONICALIZE LET


canonicalizeLet :: R.Region -> Env.Env -> [Valid.Def] -> Valid.Expr -> Result FreeLocals Can.Expr
canonicalizeLet region env defs body =
  addLocals $
  do  (bindings, boundNames) <- Pattern.canonicalizeBindings env defs
      newEnv <- Env.addLocals boundNames env
      let defKeys = Map.map A.drop boundNames
      nodes <- Result.untracked $ traverse (bindingToNode defKeys newEnv) bindings
      removeLocals defKeys $
        do  cbody <- canonicalize env body
            detectCycles region (Graph.stronglyConnComp nodes) cbody


addLocals :: Result () (expr, FreeLocals) -> Result FreeLocals expr
addLocals (Result.Result () warnings answer) =
  case answer of
    Result.Ok (value, freeLocals) ->
      Result.Result freeLocals warnings (Result.Ok value)

    Result.Err err ->
      Result.Result Set.empty warnings (Result.Err err)


removeLocals :: Map.Map N.Name a -> Result FreeLocals expr -> Result () (expr, FreeLocals)
removeLocals boundNames (Result.Result freeLocals warnings answer) =
  Result.Result () warnings $
    case answer of
      Result.Ok value ->
        Result.Ok
          ( value
          , Set.difference freeLocals (Map.keysSet boundNames)
          )

      Result.Err err ->
        Result.Err err



-- BUILD BINDINGS GRAPH


data Binding
  = Define R.Region Can.Def
  | Destruct R.Region Can.Match Can.Expr


data Node = Node Binding FreeLocals


bindingToNode :: Map.Map N.Name Int -> Env.Env -> Pattern.Binding -> Result () (Node, Int, [Int])
bindingToNode defKeys env binding =
  case binding of
    Pattern.Define region index name args body maybeType ->
      do  cargs@(Can.Args _ destructors) <- Pattern.canonicalizeArgs env args
          ctype <- traverse (Type.canonicalize env) maybeType
          newEnv <- Env.addLocals destructors env
          toNode defKeys destructors index $
            do  cbody <- canonicalize newEnv body
                return (Define region (Can.Def name cargs cbody ctype))

    Pattern.Destruct region index match body ->
      toNode defKeys Map.empty index $
        Destruct region match <$> canonicalize env body


toNode :: Map.Map N.Name Int -> Map.Map N.Name a -> Int -> Result FreeLocals Binding -> Result () (Node, Int, [Int])
toNode defKeys args index (Result.Result freeLocals warnings answer) =
  Result.Result () warnings $
  case answer of
    Result.Err err ->
      Result.Err err

    Result.Ok binding ->
      let
        actuallyFreeLocals = Set.difference freeLocals (Map.keysSet args)
        locallyDefinedLocals = Map.restrictKeys defKeys freeLocals
      in
      Result.Ok
        ( Node binding actuallyFreeLocals
        , index
        , Map.elems locallyDefinedLocals
        )



-- DETECT CYCLES


detectCycles :: R.Region -> [Graph.SCC Node] -> Can.Expr -> Result FreeLocals Can.Expr
detectCycles region sccs body =
  case sccs of
    [] ->
      Result.ok body

    scc : subSccs ->
      A.A region <$>
      case scc of
        Graph.AcyclicSCC (Node binding freeLocals) ->
          case binding of
            Define _ def ->
              Result.accumulate freeLocals (Can.Let def)
                <*> detectCycles region subSccs body

            Destruct _ match expr ->
              Result.accumulate freeLocals (Can.LetDestruct match expr)
                <*> detectCycles region subSccs body

        Graph.CyclicSCC nodes ->
          case unzip <$> traverse requireDefine nodes of
            Nothing ->
              Result.throw region (Error.RecursiveValue (map toCycleNodes nodes))

            Just (defs, freeLocals) ->
              Result.accumulate (Set.unions freeLocals) (Can.LetRec defs)
                <*> detectCycles region subSccs body



requireDefine :: Node -> Maybe (Can.Def, FreeLocals)
requireDefine (Node binding freeLocals) =
  case binding of
    Define _ def@(Can.Def _ (Can.Args args _) _ _) ->
      case args of
        [] ->
          Nothing

        _ ->
          Just (def, freeLocals)

    Destruct _ _ _ ->
      Nothing


toCycleNodes :: Node -> Error.CycleNode
toCycleNodes (Node binding _) =
  case binding of
    Define _ (Can.Def name (Can.Args args _) _ _) ->
      case args of
        [] ->
          Error.CycleValue name

        _ ->
          Error.CycleFunc name

    Destruct _ (Can.Match pattern _) _ ->
      Error.CyclePattern pattern
