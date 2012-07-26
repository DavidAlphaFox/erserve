-module(erserve_comms).

%%%_* Exports ------------------------------------------------------------------
-export([ eval/2
        , receive_connection_ack/1
        ]).


%%%_* Local definitions --------------------------------------------------------
-define(R_CMD_EVAL,           3:32/integer-little).
-define(R_MSG_LENGTH(Length), (Length+5):32/integer-little).
-define(R_EXP_LENGTH(Length), (Length+1):24/integer-little).
-define(R_OFFSET,             0:32/integer-little).
-define(R_LENGTH2,            0:32/integer-little).
-define(R_EXP(Exp),           (list_to_binary(Exp))/binary).
-define(R_TERMINATE,          0).

-define(R_RESP_OK,            16#10001:32/integer-little).
-define(R_RESP_ERROR,         16#10002:32/integer-little).

-define(DT_INT,               1).
-define(DT_CHAR,              2).
-define(DT_DOUBLE,            3).
-define(DT_STRING,            4).
-define(DT_BYTESTREAM,        5).
-define(DT_SEXP,              10).
-define(DT_ARRAY,             11).
-define(DT_LARGE,             64).

-define(R_DT_STRING,          ?DT_STRING:8/integer-little).

-define(XT_STR,               3).
-define(XT_VECTOR,            16).
-define(XT_CLOS,              18).
-define(XT_SYMNAME,           19).
-define(XT_LIST_TAG,          21).
-define(XT_VECTOR_EXP,        26).
-define(XT_ARRAY_DOUBLE,      33).
-define(XT_ARRAY_STR,         34).

-define(XT_HAS_ATTR,          128).

-define(ERR_AUTH_FAILED,      65).
-define(ERR_CONN_BROKEN,      66).
-define(ERR_INV_CMD,          67).
-define(ERR_INV_PAR,          68).
-define(ERR_R_ERROR,          69).
-define(ERR_IO_ERROR,         70).
-define(ERR_NOT_OPEN,         71).
-define(ERR_ACCESS_DENIED,    72).
-define(ERR_UNSUPPORTED_CMD,  73).
-define(ERR_UNKNOWN_CMD,      74).
-define(ERR_DATA_OVERFLOW,    75).
-define(ERR_OBJECT_TOO_BIG,   76).
-define(ERR_OUT_OF_MEM,       77).
-define(ERR_CTRL_CLOSED,      78).
-define(ERR_SESSION_BUSY,     80).
-define(ERR_DETACH_FAILED,    81).


%%%_* External API -------------------------------------------------------------
receive_connection_ack(Sock) ->
  {ok, Msg} = gen_tcp:recv(Sock, 32),
  <<"Rsrv", _Version:32, _Protocol:32, _Extra/binary>> = Msg,
  ok.

eval(Sock, Command) ->
  ok = send_expression(Sock, Command),
  receive_reply(Sock).


%%%_* Internal functions -------------------------------------------------------
send_expression(Sock, Expr) ->
  Length  = length(Expr),
  Message = << ?R_CMD_EVAL
             , ?R_MSG_LENGTH(Length)
             , ?R_OFFSET
             , ?R_LENGTH2
             , ?R_DT_STRING
             , ?R_EXP_LENGTH(Length)
             , ?R_EXP(Expr)
             , ?R_TERMINATE
            >>,
  gen_tcp:send(Sock, Message).

receive_reply(Sock) ->
  {ok, AckCode} = gen_tcp:recv(Sock, 4),
  case AckCode of
    <<?R_RESP_OK>> -> receive_reply_1(Sock);
    _              -> receive_reply_error(AckCode, Sock)
  end.

receive_reply_1(Sock) ->
  {ok, Msg} = gen_tcp:recv(Sock, 12),
  << Len0:32/integer-little
   , _Offset:32/integer-little
   , Len1:32/integer-little
  >>   = Msg,
  Len  = Len0 + (Len1 bsl 31),
  {ok, receive_data(Sock, Len)}.

receive_reply_error(AckCode, Sock) ->
  <<2,0,1,ErrCode>> = AckCode,
  Error             = error_from_code(ErrCode),
  {ok, Rest}        = gen_tcp:recv(Sock, 0),
  {error, Error, Rest}.

%%%_* Data receiving functions -------------------------------------------------
receive_data(Sock, Length) ->
  lists:reverse(receive_data(Sock, Length, [])).

receive_data(_Sock, 0, Acc) ->
  Acc;
receive_data( Sock, Length, Acc) ->
  {ok, Header} = gen_tcp:recv(Sock, 4),
  << Type:8/integer-little
   , ItemLength:24/integer-little
  >> = Header,
  {Item, _L} = receive_item(Sock, Type),
  NewAcc = [Item|Acc],
  RemainingLength = Length - ItemLength - 4,
  receive_data(Sock, RemainingLength, NewAcc).

receive_item(Sock, ?DT_SEXP) ->
  {ok, Header} = gen_tcp:recv(Sock, 4),
  << SexpType:8/integer-little
   , SexpLength:24/integer-little
  >> = Header,
  Item = receive_sexp(Sock, SexpType, SexpLength),
  {Item, SexpLength + 4}.

receive_sexp(Sock, Type,             Length) when Type > ?XT_HAS_ATTR ->
  %% SEXP has attributes, so we need to read off the attribute SEXP
  %% before we get to this expression proper
  {AttrSexp, AttrSexpLength} = receive_item(Sock, ?DT_SEXP),
  Sexp                       = receive_sexp(Sock,
                                            Type - ?XT_HAS_ATTR,
                                            Length - AttrSexpLength),
  {attr_sexp, [ {attributes, AttrSexp}, Sexp ]};
receive_sexp(Sock, ?XT_STR,          Length)                          ->
  Strings = receive_string_array(Sock, Length),
  {string, hd(Strings)};
receive_sexp(Sock, ?XT_VECTOR,       Length)                          ->
  Vector = receive_vector(Sock, Length, []),
  {vector, Vector};
receive_sexp(Sock, ?XT_SYMNAME,      Length)                          ->
  receive_sexp(Sock, ?XT_STR, Length);
receive_sexp(Sock, ?XT_LIST_TAG,     Length)                          ->
  TagList = receive_tagged_list(Sock, Length, []),
  {tagged_list, TagList};
receive_sexp(Sock, ?XT_VECTOR_EXP,   Length)                          ->
  receive_sexp(Sock, ?XT_VECTOR, Length);
receive_sexp(Sock, ?XT_CLOS,         Length)                          ->
  Closure = receive_closure(Sock, Length),
  {closure, Closure};
receive_sexp(Sock, ?XT_ARRAY_DOUBLE, Length)                          ->
  Array = receive_double_array(Sock, Length, []),
  {{array, double}, Array};
receive_sexp(Sock, ?XT_ARRAY_STR,    Length)                          ->
  Array = receive_string_array(Sock, Length),
  {{array, string}, Array}.

receive_closure(Sock, Length) ->
  {ok, Closure} = gen_tcp:recv(Sock, Length),
  Closure.

receive_double_array(_Sock, 0,      Acc) ->
  lists:reverse(Acc);
receive_double_array( Sock, Length, Acc) ->
  Double          = receive_double(Sock),
  NewAcc          = [Double|Acc],
  RemainingLength = Length - 8,
  receive_double_array(Sock, RemainingLength, NewAcc).

receive_double(Sock) ->
  {ok, Data}                 = gen_tcp:recv(Sock, 8),
  <<Double:64/float-little>> = Data,
  Double.

receive_string_array(Sock, Length) ->
  {ok, Data} = gen_tcp:recv(Sock, Length),
  %% Strip off '\01'-padding, and split on null terminators
  String     = string:strip(binary_to_list(Data), right, 1),
  string:tokens(String, [0]).

receive_tagged_list(_Sock, 0,      Acc) ->
  lists:reverse(Acc);
receive_tagged_list( Sock, Length, Acc) ->
  {Value, ValueLength} = receive_item(Sock, ?DT_SEXP),
  {Key,   KeyLength}   = receive_item(Sock, ?DT_SEXP),
  Item                 = [ {key,   Key}
                         , {value, Value}
                         ],
  NewAcc               = [Item|Acc],
  RemainingLength      = Length - KeyLength - ValueLength,
  receive_tagged_list(Sock, RemainingLength, NewAcc).

receive_vector(_Sock, 0,      Acc) ->
  lists:reverse(Acc);
receive_vector( Sock, Length, Acc) ->
  {Item, UsedLength} = receive_item(Sock, ?DT_SEXP),
  NewAcc = [Item|Acc],
  RemainingLength = Length - UsedLength,
  receive_vector(Sock, RemainingLength, NewAcc).


%%%_* Error handling -----------------------------------------------------------
error_from_code(?ERR_AUTH_FAILED)     ->
  auth_failed;
error_from_code(?ERR_CONN_BROKEN)     ->
  connection_broken;
error_from_code(?ERR_INV_CMD)         ->
  invalid_command;
error_from_code(?ERR_INV_PAR)         ->
  invalid_parameters;
error_from_code(?ERR_R_ERROR)         ->
  r_error_occurred;
error_from_code(?ERR_IO_ERROR)        ->
  io_error;
error_from_code(?ERR_NOT_OPEN)        ->
  file_not_open;
error_from_code(?ERR_ACCESS_DENIED)   ->
  access_denied;
error_from_code(?ERR_UNSUPPORTED_CMD) ->
  unsupported_command;
error_from_code(?ERR_UNKNOWN_CMD)     ->
  unknown_command;
error_from_code(?ERR_DATA_OVERFLOW)   ->
  data_overflow;
error_from_code(?ERR_OBJECT_TOO_BIG)  ->
  object_too_big;
error_from_code(?ERR_OUT_OF_MEM)      ->
  out_of_memory;
error_from_code(?ERR_CTRL_CLOSED)     ->
  control_pipe_closed;
error_from_code(?ERR_SESSION_BUSY)    ->
  session_busy;
error_from_code(?ERR_DETACH_FAILED)   ->
  unable_to_detach_session;
error_from_code(Other)                ->
  {unknown_error, Other}.
