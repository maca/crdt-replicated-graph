module CRDTree exposing
  ( CRDTree
  , Error(..)
  , init
  , add
  , addBranch
  , delete
  , batch
  , apply
  , operationsSince
  , lastOperation
  , id
  , root
  , get
  , cursor
  , moveCursorUp
  )

{-| `CRDTree` is a Replicated Tree, it keeps the local replica
state.
The timestamp for adding nodes is calculated by adding
`maxReplicas` count to the last timestamp, and the initial
timestamp corresponds to the `ReplicaId`.
This sets two constraints: the `ReplicaId` has to be unique for
each replica, and the maximum number of replicas has to be
declared.

# Init

@docs CRDTree
@docs init

# Operations

@docs Error
@docs add
@docs addBranch
@docs batch
@docs delete
@docs apply
@docs operationsSince
@docs lastOperation

# Tree

@docs id
@docs root
@docs get
@docs cursor
@docs moveCursorUp

-}

import Dict exposing (Dict, keys)
import List exposing (head)
import Result

import CRDTree.List exposing
  ( Error(..)
  , replaceWhen
  , insertWhen
  , applyWhen
  , find
  )
import CRDTree.Node as Node exposing (Node(..))
import CRDTree.Operation as Operation exposing (Operation(..))
import CRDTree.ReplicaId as ReplicaId exposing (ReplicaId)


{-| Represents the failure to apply an operation
-}
type Error a =
  Error (Operation a)


{-| Opaque type representing a Replicated Tree,
to build see [int](#init).
-}
type CRDTree a =
  CRDTree
    { replicaId: ReplicaId
    , maxReplicas: Int
    , root : Node a
    , timestamp: Int
    , cursor: List Int
    , operations: List (Operation a)
    , replicas: Dict Int Int
    , lastOperation: Operation a
    }


type alias UpdateFun a =
  Maybe Int -> List (Node a)
            -> Result CRDTree.List.Error (List (Node a))


type alias NodeFun a =
  List Int -> Maybe Int -> Node a


{-| Build a CRDTree

    tree : CRDTree String
    tree = init { id = 1, maxReplicas = 1024 }

`id` for this replica, not two replicas can have the same id. To
ensure this, it shuld be assigned by a server.

`maxReplicas` maximum number of possible replicas, this value has
to be assigned to generate unique timestamps.
-}
init : { id: Int, maxReplicas: Int } -> CRDTree a
init params =
  CRDTree
    { replicaId = ReplicaId.fromInt params.id
    , maxReplicas = params.maxReplicas
    , operations = []
    , cursor = [0]
    , replicas = Dict.empty
    , root = Node.root
    , timestamp = 0
    , lastOperation = Batch []
    }


{-| Build and add a node after tree cursor, the cursor is set
at the added node path.

    init { id = 1, maxReplicas = 4 }
      |> add "a"
      |> Result.andThen (add "b")
      |> Result.andThen (add "c")

-}
add : a -> CRDTree a -> Result (Error a) (CRDTree a)
add value (CRDTree record as tree) =
  let
      newTimestamp = nextTimestamp tree record.timestamp
  in
      applyLocal (Add record.replicaId newTimestamp record.cursor value) tree


{-| Build and add a branch after tree cursor, subsequent
additions are added to the branch.

    init { id = 1, maxReplicas = 4 }
      |> addBranch "a"
      |> Result.andThen (add "a,b")
      |> Result.andThen (add "a,c")
-}
addBranch : a -> CRDTree a -> Result (Error a) (CRDTree a)
addBranch value rga =
  add value rga |> Result.map branchCursor


{-| Mark a node at a path as deleted.

    init { id = 1, maxReplicas = 4 }
      |> batch [ add "a", add "b" ]
      |> Result.andThen (\tree -> delete (cursor tree) tree)

Nodes are not actually deleted but marked and their children
discarded.
-}
delete : List Int -> CRDTree a -> Result (Error a) (CRDTree a)
delete path (CRDTree record as tree) =
  applyLocal (Delete record.replicaId path) tree


{-| Apply a list of operations

    init { id = 1, maxReplicas = 4 }
      |> batch [ add "a", add "b", add "c" ]
-}
batch : List (CRDTree a -> Result (Error a) (CRDTree a))
      -> CRDTree a
      -> Result (Error a) (CRDTree a)
batch funs rga =
  applyBatch funs rga


{-| Apply a remote operation

    treeA : CRDTree String
    treeA =
      let
          tree =
            init { id = 1, maxReplicas = 2 }
      in
      tree
        |> batch [ add "a", add "b", add "c" ]
        |> Result.withDefault tree

    operation : Operation String
    operation =
      lastOperation treeA

    treeB : CRDTree String
    treeB =
      let
          tree =
            init { id = 1, maxReplicas = 2 }
      in
      tree
        |> apply operation
        |> Result.withDefault tree

    (root treeA) == (root treeB)
    (operations treeA) == (operations treeB)
    (path treeA) /= (path treeB)
    (timestamp treeA) /= (timestamp treeB)

-}
apply : Operation a -> CRDTree a -> Result (Error a) (CRDTree a)
apply operation tree =
  applyLocal operation tree
    |> Result.map (\(CRDTree record) ->
        CRDTree { record | cursor = record.cursor })


{-| Apply a local operation, the cursor for the `CRDTree` will
change
-}
applyLocal : Operation a -> CRDTree a -> Result (Error a) (CRDTree a)
applyLocal operation (CRDTree record as tree) =
  let
      mapResult rid timestamp path result =
        case result of
          Err AlreadyApplied ->
            Ok <| CRDTree { record | lastOperation = Batch [] }

          Err TombstoneUpdate ->
            Ok <| CRDTree { record | lastOperation = Batch [] }

          Err exp ->
            Err <| Error operation

          Ok node ->
            let
                update =
                  updateTimestamp rid timestamp
                    >> appendOperation operation
                    >> updateCursor timestamp path
            in
                Ok <| update <| CRDTree { record | root = node }
  in
      case operation of
        Add replica timestamp path value ->
          let
              nodePath =
                List.reverse path
                  |> List.tail
                  |> Maybe.withDefault []
                  |> ((::) timestamp)
                  |> List.reverse
          in
              updateBranch (addFun value nodePath) path record.root
                |> mapResult replica timestamp path

        Delete replica path ->
          let
              timestamp =
                Operation.timestamp operation |> Maybe.withDefault 0
          in
              updateBranch (deleteFun path) path record.root
                |> mapResult replica timestamp path

        Batch ops ->
          applyBatch (List.map apply ops) tree


applyBatch funcs (CRDTree record as tree) =
  batchFold tree funcs
    (Ok <| CRDTree { record | lastOperation = Batch [] })


batchFold : CRDTree a -> List (CRDTree a -> Result (Error a) (CRDTree a))
                      -> Result (Error a) (CRDTree a)
                      -> Result (Error a) (CRDTree a)
batchFold rga opFuns result =
  case opFuns of
    [] ->
      result

    f :: fs ->
      let
          fun = f >> Result.map2 mergeLastOperation result
      in
          batchFold rga fs ((Result.andThen fun) result)


addFun : a -> List Int
           -> Maybe Int
           -> List (Node a)
           -> Result CRDTree.List.Error (List (Node a))
addFun value path maybePreviousTs nodes =
  let
      node =
        Node.init value path

      timestamp =
        Node.timestamp node

  in
      case maybePreviousTs of
        Just previousTs ->
          insertWhen (\n -> (Node.timestamp n) == previousTs) node nodes

        Nothing ->
          case find (\n -> (Node.timestamp n) == timestamp) nodes of
            Just _ ->
              Err AlreadyApplied

            Nothing ->
              Ok [ node ]


deleteFun : List Int -> Maybe Int
                     -> List (Node a)
                     -> Result CRDTree.List.Error (List (Node a))
deleteFun path maybePreviousTs nodes =
  case maybePreviousTs of
    Just previousTs ->
      let
          node = Node.tombstone path
          pred = (\n -> (Node.timestamp n) == previousTs)
      in
          replaceWhen pred node nodes

    Nothing ->
      Err NotFound


updateBranch : UpdateFun a -> List Int
                           -> Node a
                           -> Result CRDTree.List.Error (Node a)
updateBranch fun path parent =
  if Node.isDeleted parent then
    Err TombstoneUpdate
  else
    updateBranchHelp fun path parent <| Node.children parent


updateBranchHelp fun path parent children =
  case path of
    [] ->
      Err NotFound

    [0] ->
      fun Nothing children |> updateChildren parent

    ts :: [] ->
      fun (Just ts) children |> updateChildren parent

    ts :: tss ->
      let
          update node =
            updateBranch fun tss node
              |> Result.map List.singleton
      in
          applyWhen (\n -> (Node.timestamp n) == ts) update children
            |> updateChildren parent


updateChildren : Node a -> Result CRDTree.List.Error (List (Node a))
                        -> Result CRDTree.List.Error (Node a)
updateChildren parent result =
  Result.map (\children -> Node.updateChildren children parent) result


branchCursor : CRDTree a -> CRDTree a
branchCursor (CRDTree record) =
  CRDTree { record | cursor = record.cursor ++ [0] }


mergeLastOperation : CRDTree a -> CRDTree a -> CRDTree a
mergeLastOperation (CRDTree record1) (CRDTree record2) =
  let
      operations1 = record1.lastOperation
      operations2 = record2.lastOperation
      operation   = Operation.merge operations1 operations2
  in
    CRDTree { record2 | lastOperation = operation }


updateCursor : Int -> List Int -> CRDTree a -> CRDTree a
updateCursor timestamp path (CRDTree record) =
  CRDTree { record | cursor = buildPath timestamp path }


appendOperation : Operation a -> CRDTree a -> CRDTree a
appendOperation operation (CRDTree record) =
  CRDTree
    { record | operations = operation :: record.operations
    , lastOperation = operation
    }


updateTimestamp : ReplicaId -> Int -> CRDTree a -> CRDTree a
updateTimestamp rid operationTimestamp (CRDTree record as tree) =
  let
      timestamp =
        mergeTimestamp tree record.timestamp operationTimestamp

      replicaId =
        ReplicaId.toInt rid
  in
      CRDTree
        { record | timestamp = timestamp
        , replicas = Dict.insert replicaId operationTimestamp record.replicas
        }


mergeTimestamp : CRDTree a -> Int -> Int -> Int
mergeTimestamp rga timestamp operationTimestamp =
  if timestamp >= operationTimestamp then
    timestamp
  else
    let
        next =
          nextTimestamp rga timestamp
    in
        mergeTimestamp rga next operationTimestamp


{-| Get the next timestamp
-}
nextTimestamp : CRDTree a -> Int -> Int
nextTimestamp (CRDTree record) timestamp =
  timestamp + record.maxReplicas


{-| Return the last successfully applied operation or batch
or if operation was not succesfull an empty batch.

      import Operation exposing (Operation(..))

      -- success
      init { id = 1, maxReplicas = 1 }
        |> batch [ add "a", add "b", add "c" ]
        |> Result.map (\tree ->
             (lastOperation tree) /= Batch [])

      -- failure
      init { id = 1, maxReplicas = 1 }
        |> delete [1,2,3]
        |> Result.map (\tree ->
            (lastOperation tree) == Batch [])

-}
lastOperation : CRDTree a -> Operation a
lastOperation (CRDTree record) =
  record.lastOperation


{-| The local replica id
-}
id : CRDTree a -> Int
id (CRDTree record) =
  ReplicaId.toInt record.replicaId


{-| Return a list of operations after a known timestamp

    treeA : CRDTree String
    treeA =
      let
          tree =
            init { id = 1, maxReplicas = 2 }
      in
      tree
        |> batch [ add "a", add "b" ]
        |> Result.withDefault tree

    (List.length (operationsSince 0 treeA)) == 2
    (List.length (operationsSince 2 treeA)) == 2
    (List.length (operationsSince 4 treeA)) == 1

    -- 1, 3 are not known timestamps, since the
    -- logic clock increment depends on `maxReplicas`
    (List.length (operationsSince 1 treeA)) == 0
    (List.length (operationsSince 3 treeA)) == 0
-}
operationsSince : Int -> CRDTree a -> List (Operation a)
operationsSince timestamp (CRDTree record) =
  case timestamp of
    0 ->
      record.operations |> List.reverse

    _ ->
      Operation.since timestamp record.operations


{-| Root node of the CRDTree
-}
root : CRDTree a -> Node a
root (CRDTree record) =
  record.root


{-| Get a value at path

    treeA : CRDTree String
    treeA =
      let
          tree =
            init { id = 1, maxReplicas = 1 }
      in
      tree
        |> batch [ addBranch "a", addBranch "b", add "c" ]
        |> Result.withDefault tree

    (get [1] treeA) == (Just "a")
    (get [1, 2] treeA) == (Just "b")
    (get [1, 2, 3] treeA) == (Just "c")
    (get [4] treeA) == Nothing

-}
get : List Int -> CRDTree a -> Maybe a
get path (CRDTree record) =
  Node.descendant path record.root |> Maybe.andThen Node.value


{-| Return the tree cursor

    treeA : CRDTree String
    treeA =
      let
          tree =
            init { id = 1, maxReplicas = 1 }
      in
      tree
        |> batch [ add "a", add "b", add "c" ]
        |> Result.withDefault tree

    (cursor treeA) == [3]


    treeB : CRDTree String
    treeB =
      let
          tree =
            init { id = 1, maxReplicas = 1 }
      in
      tree
        |> batch [ addBranch "a", addBranch "b" ]
        |> Result.withDefault tree

    (cursor treeB) == [1, 2, 0]

-}
cursor : CRDTree a -> List Int
cursor (CRDTree record) =
  record.cursor


{-| Move the tree cursor one level up

    treeA : CRDTree String
    treeA =
      let
          tree =
            init { id = 1, maxReplicas = 1 }
      in
      tree
        |> batch [ addBranch "a", addBranch "b", add "c" ]
        |> Result.withDefault tree

    (cursor treeA) == [1, 2, 3]
    (cursor (moveCursorUp treeA)) == [1, 2]

-}
moveCursorUp : CRDTree a -> CRDTree a
moveCursorUp (CRDTree record as tree) =
  let
      newCursor =
        List.head (cursor tree)
        |> Maybe.withDefault 0
        |> List.singleton
  in
      CRDTree { record | cursor = newCursor }


buildPath : Int -> List Int -> List Int
buildPath timestamp path =
  case List.reverse path of
    [] ->
      [ timestamp ]

    _ :: rest ->
      List.reverse <| timestamp :: rest

