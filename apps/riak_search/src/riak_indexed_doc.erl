%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_indexed_doc).

-export([
    new/4,
    index/1, id/1, 
    fields/1, regular_fields/1, facets/1,
    props/1, add_prop/3, set_props/2, clear_props/1, 
    postings/1,
    to_mochijson2/1, to_mochijson2/2,
    analyze/1, analyze/2,
    new_obj/2, get_obj/3, put_obj/2, get/3, put/2, 
    delete/2, delete/3
]).

-include("riak_search.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-import(riak_search_utils, [to_binary/1]).

%% Create a new indexed doc
new(Id, Fields, Props, Index) ->
    {ok, Schema} = riak_search_config:get_schema(Index),
    {RegularFields, FacetFields} = normalize_fields(Fields, Schema),
    #riak_idx_doc{ index=to_binary(Index),
                   id=to_binary(Id), 
                   fields=RegularFields, 
                   facets=FacetFields, 
                   props=Props }.

fields(IdxDoc) ->
    regular_fields(IdxDoc) ++ facets(IdxDoc).

regular_fields(#riak_idx_doc{fields=Fields}) ->
    [{FieldName, FieldValue} || {FieldName, FieldValue, _} <- Fields].

facets(#riak_idx_doc{facets=Facets}) ->
    [{FieldName, FieldValue} || {FieldName, FieldValue, _} <- Facets].

index(#riak_idx_doc{index=Index}) ->
    Index.

id(#riak_idx_doc{id=Id}) ->
    Id.

props(#riak_idx_doc{props=Props}) ->
    Props.

add_prop(Name, Value, #riak_idx_doc{props=Props}=Doc) ->
    Doc#riak_idx_doc{props=[{Name, Value}|Props]}.

set_props(Props, Doc) ->
    Doc#riak_idx_doc{props=Props}.

clear_props(Doc) ->
    Doc#riak_idx_doc{props=[]}.

%% Construct a list of [{Index, Field, Term, Id, Props, Timestamp}]
%% from previously analyzed results.
postings(IdxDoc) ->
    %% Get some values.
    DocIndex = ?MODULE:index(IdxDoc),
    DocId = ?MODULE:id(IdxDoc),
    Facets = ?MODULE:facets(IdxDoc),
    K = riak_search_utils:current_key_clock(),
    
    %% Fold over each regular field, and then fold over each term in
    %% that field.
    F1 = fun({FieldName, _, TermPos}, FieldsAcc) ->
                 F2 = fun({Term, Positions}, Acc) ->
                              Props = build_props(Positions, Facets),
                              [{DocIndex, FieldName, Term, DocId, Props, K} | Acc]
                      end,
                 lists:foldl(F2, FieldsAcc, TermPos)
         end,
    lists:foldl(F1, [], IdxDoc#riak_idx_doc.fields).

%% Currently unused?
%% to_json(Doc) ->
%%     mochijson2:encode(to_mochijson2(Doc)).

to_mochijson2(Doc) ->
    F = fun({_Name, Value}) -> Value end,
    to_mochijson2(F, Doc).

to_mochijson2(XForm, #riak_idx_doc{id=Id, index=Index, fields=Fields, facets=Facets, props=Props}) ->
    {struct, [{id, riak_search_utils:to_binary(Id)},
              {index, riak_search_utils:to_binary(Index)},
              {fields, {struct, [{riak_search_utils:to_binary(Name),
                                  XForm({Name, Value})} || {Name, Value, _} <- lists:keysort(1, Fields ++ Facets)]}},
              {props, {struct, [{riak_search_utils:to_binary(Name),
                                 riak_search_utils:to_binary(Value)} || {Name, Value} <- Props]}}]}.

%% Currently Unused?
%% from_json(Json) ->
%%     case mochijson2:decode(Json) of
%%         {struct, Data} ->
%%             Id = proplists:get_value(<<"id">>, Data),
%%             Index = proplists:get_value(<<"index">>, Data),
%%             build_doc(Id, Index, Data);
%%         {error, _} = Error ->
%%             Error;
%%         _NonsenseJson ->
%%             {error, bad_json_format}
%%     end.

%% %% @private
%% build_doc(Id, Index, _Data) when Id =:= undefined orelse
%%                                  Index =:= undefined ->
%%     {error, missing_id_or_index};
%% build_doc(Id, Index, Data) ->
%%     Fields = [{Name, Value, []} || {Name, Value} <- read_json_fields(<<"fields">>, Data)),
%%     Props = read_json_fields(<<"props">>, Data),
%%     #riak_idx_doc{id=riak_search_utils:from_binary(Id), 
%%                   index=binary_to_list(Index),
%%                   fields=Fields,
%%                   props=Props}.
        
%% %% @private
%% read_json_fields(Key, Data) ->
%%     case proplists:get_value(Key, Data) of
%%         {struct, Fields} ->
%%             [{riak_search_utils:from_binary(Name),
%%               riak_search_utils:from_binary(Value)} || {Name, Value} <- Fields];
%%         _ ->
%%             []
%%     end.

%% Parse a #riak_idx_doc{} record.
%% Return {ok, [{Index, FieldName, Term, DocID, Props}]}.
analyze(IdxDoc) when is_record(IdxDoc, riak_idx_doc) ->
    {ok, AnalyzerPid} = qilr:new_analyzer(),
    try
        analyze(IdxDoc, AnalyzerPid)
    after
        qilr:close_analyzer(AnalyzerPid)
    end.


%% Parse a #riak_idx_doc{} record using the provided analyzer pid.
%% Return {ok, [{Index, FieldName, Term, DocID, Props}]}.
analyze(IdxDoc, _AnalyzerPid) 
  when is_record(IdxDoc, riak_idx_doc) andalso IdxDoc#riak_idx_doc.analyzed_flag == true ->
    %% Don't re-analyze an already analyzed idx doc.
    IdxDoc;
analyze(IdxDoc, AnalyzerPid) when is_record(IdxDoc, riak_idx_doc) ->
    %% Extract fields, get schema...
    DocIndex = ?MODULE:index(IdxDoc),
    RegularFields = ?MODULE:regular_fields(IdxDoc),
    Facets = ?MODULE:facets(IdxDoc),
    {ok, Schema} = riak_search_config:get_schema(DocIndex),
    
    %% For each Field = {FieldName, FieldValue, _}, split the FieldValue
    %% into terms and build a list of positions for those terms.
    F = fun({FieldName, FieldValue}, Acc2) ->
                {ok, Terms} = analyze_field(FieldName, FieldValue, Schema, AnalyzerPid),
                [{FieldName, FieldValue, get_term_positions(Terms)} | Acc2]
        end,
    NewFields = lists:foldl(F, [], RegularFields),
    NewFacets = lists:foldl(F, [], Facets),

    %% For each Facet = {FieldName, FieldValue, _}, split the FieldValue
    %% into terms and build a list of positions for those terms.
    {ok, IdxDoc#riak_idx_doc{ fields=NewFields, facets=NewFacets, analyzed_flag=true }}.

%% Normalize the list of input fields against the schema
%% - drop any skip fields
%% - replace any aliased fields with the correct name
%% - combine duplicate field names into a single field (separate by spaces)
normalize_fields(DocFields, Schema) ->
    Fun = fun({InFieldName, FieldValue}, {Regular, Facets}) ->
                  FieldDef = Schema:find_field(InFieldName),
                  case Schema:is_skip(FieldDef) of
                      true ->
                          {Regular, Facets};
                      false ->
                          %% Create the field. Use an empty list
                          %% placeholder for term positions. This gets
                          %% filled when we analyze the document.
                          NormFieldName = normalize_field_name(InFieldName, FieldDef, Schema),
                          NormFieldValue = to_binary(FieldValue),
                          Field = {NormFieldName, NormFieldValue, []},
                          case Schema:is_field_facet(FieldDef) of
                              true ->
                                  {Regular, [Field | Facets]};
                              false ->
                                  {[Field | Regular], Facets}
                          end
                  end
          end,
    {RevRegular, RevFacets} = lists:foldl(Fun, {[], []}, DocFields),
    
    %% Aliasing makes it possible to have multiple entries in
    %% RevRegular.  Combine multiple entries for the same field name
    %% into a single field.
    {merge_fields(lists:reverse(RevRegular)), 
     merge_fields(lists:reverse(RevFacets))}.

%% @private
%% Normalize the field name - if an alias of a regular field
%% then replace it with the defined name.  Dynamic field names
%% are just passed through.
normalize_field_name(FieldName, FieldDef, Schema) ->
    case Schema:is_dynamic(FieldDef) of
        true ->
            to_binary(FieldName);
        _ ->
            to_binary(Schema:field_name(FieldDef))
    end.

%% @private
%% Merge fields of the same name, with spaces between them
merge_fields(DocFields) ->
    %% Use lists:keysort as it gives stable ordering of values.  If multiple
    %% fields are given they'll be combined in order which is probably least
    %% suprising for users.
    lists:foldl(fun merge_fields_folder/2, [], lists:keysort(1, DocFields)).

%% @private
%% Merge field data with previous if the names match.  Input must be sorted.
merge_fields_folder({FieldName, NewFieldData, NewTermPos}, [{FieldName, FieldData, TermPos} | Fields]) ->
    Field = {FieldName, <<FieldData/binary, " ", NewFieldData/binary>>, TermPos ++ NewTermPos},
    [Field | Fields];
merge_fields_folder(New, Fields) ->
    [New | Fields].
      

%% @private
%% Parse a FieldValue into a list of terms.
%% Return {ok, [Terms}}.
analyze_field(FieldName, FieldValue, Schema, AnalyzerPid) ->
    %% Get the field...
    Field = Schema:find_field(FieldName),
    AnalyzerFactory = Schema:analyzer_factory(Field),
    AnalyzerArgs = Schema:analyzer_args(Field),

    %% Analyze the field...
    qilr_analyzer:analyze(AnalyzerPid, FieldValue, AnalyzerFactory, AnalyzerArgs).


%% @private Given a list of tokens, build a gb_tree mapping words to a
%% list of word positions.
get_term_positions(Terms) ->
    %% Use a table to accumulate a list of term positions.
    Table = ets:new(positions, [duplicate_bag]),
    F1 = fun(Term, Pos) ->
                ets:insert(Table, [{Term, Pos}]),
                Pos + 1
        end,
    lists:foldl(F1, 0, Terms),

    %% Look up the keys for the table...
    F2 = fun(Term) ->
                 {Term, [Pos || {_, Pos} <- ets:lookup(Table, Term)]}
         end,
    Keys = riak_search_utils:ets_keys(Table),
    Positions = [F2(X) || X <- Keys],
    
    %% Delete the table and return.
    ets:delete(Table),
    Positions.

%% @private
%% Given a term and a list of positions, generate a list of
%% properties.
build_props(Positions, Facets) ->
    [{p, Positions}| Facets].

%% Returns a Riak object.
get_obj(RiakClient, DocIndex, DocID) ->
    Bucket = idx_doc_bucket(DocIndex),
    Key = to_binary(DocID),
    RiakClient:get(Bucket, Key).

%% Returns a #riak_idx_doc record.
get(RiakClient, DocIndex, DocID) ->
    case get_obj(RiakClient, DocIndex, DocID) of
        {ok, Obj} -> 
            riak_object:get_value(Obj);
        Other ->
            Other
    end.

new_obj(DocIndex, DocID) ->
    DocBucket = idx_doc_bucket(DocIndex),
    DocKey = to_binary(DocID),
    riak_object:new(DocBucket, DocKey, undefined).

%% Write the object to Riak.
put(RiakClient, IdxDoc) ->
    DocIndex = index(IdxDoc),
    DocID = id(IdxDoc),
    DocBucket = idx_doc_bucket(DocIndex),
    DocKey = to_binary(DocID),
    case RiakClient:get(DocBucket, DocKey) of
        {ok, Obj} -> 
            DocObj = riak_object:update_value(Obj, IdxDoc);
        {error, notfound} ->
            DocObj = riak_object:new(DocBucket, DocKey, IdxDoc)
    end,
    RiakClient:put(DocObj).

put_obj(RiakClient, RiakObj) ->
    RiakClient:put(RiakObj).
    

delete(RiakClient, IdxDoc) ->
    delete(RiakClient, index(IdxDoc), id(IdxDoc)).

delete(RiakClient, DocIndex, DocID) ->
    DocBucket = idx_doc_bucket(DocIndex),
    DocKey = to_binary(DocID),
    RiakClient:delete(DocBucket, DocKey).


idx_doc_bucket(Bucket) when is_binary(Bucket) ->
    <<"_rsid_", Bucket/binary>>;
idx_doc_bucket(Bucket) ->
    idx_doc_bucket(to_binary(Bucket)).

-ifdef(TEST).

normalize_fields_test() ->
    SchemaProps = [{version, 1},{default_field, "afield"}],
    FieldDefs =  [{field, [{name, "skipme"},
                           {alias, "skipmetoo"},
                           skip]},
                  {field, [{name, "afield"},
                           {alias, "afieldtoo"}]},
                  {field, [{name, "anotherfield"},
                           {alias, "anotherfieldtoo"}]},
                  {field, [{name, "afacet"},
                           {alias, "afacettoo"},
                           facet]},
                  {field, [{name, "anotherfacet"},
                           {alias, "anotherfacettoo"},
                           {facet, true}]}],
    
    SchemaDef = {schema, SchemaProps, FieldDefs},
    {ok, Schema} = riak_search_schema_parser:from_eterm(is_skip_test, SchemaDef),

    ?assertEqual({[], []}, normalize_fields([], Schema)),    
    ?assertEqual({[{<<"afield">>,<<"data">>, []}], []}, normalize_fields([{"afield","data"}], Schema)),
    ?assertEqual({[{<<"afield">>,<<"data">>, []}], []}, normalize_fields([{"afieldtoo","data"}], Schema)),
    ?assertEqual({[{<<"afield">>,<<"one two three">>, []}], []}, 
                 normalize_fields([{"afieldtoo","one"},
                                   {"afield","two"},
                                   {"afieldtoo", "three"}], Schema)),
    ?assertEqual({[{<<"anotherfield">>, <<"abc def ghi">>, []},
                   {<<"afield">>,<<"one two three">>, []}],
                  [{<<"afacet">>, <<"first second">>, []}]},
                 normalize_fields([{"anotherfield","abc"},
                                   {"afieldtoo","one"},
                                   {"skipme","skippable terms"},
                                   {"anotherfieldtoo", "def"},
                                   {"afield","two"},
                                   {"skipmetoo","not needed"},
                                   {"anotherfield","ghi"},
                                   {"afieldtoo", "three"},
                                   {"afacet", "first"},
                                   {"afacettoo", "second"}], Schema)).

-endif. % TEST
