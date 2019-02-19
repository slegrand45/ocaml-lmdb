(** OCaml binding for LMDB. *)

(** The {{:http://www.lmdb.tech/doc/}LMDB} database
    is a fast in-file key-value store that supports ACID transactions.

    These bindings attempt to expose a typesafe yet low-overhead API.

    First, an environment must be opened using {!Env.create}:

    {[let env = Env.(create rw ~flags:Flags.no_subdir "mydb") ]}

    Now the data file [mydb] and lock file [mydb-lock] have been created
    in the current directory.

    One environment may contain multiple named and one unnamed key-value stores.
    They are called {e databases} in the

    A single [('keyey, 'valuealue, [< `Read | `Write])] {!type: Db.t} is a key-value store mapping
    OCaml values of type ['keyey] to values of type ['valuealue].
    Multiple values per key are supported on request.

    Using {!Db}, we can open the unnamed db and add our first value:
{[
let db = Db.(open_existing ~key:Conv.string ~value:Conv.string env) in
Db.put db "Bactrian camel" "Elegant and beautiful animal with two humps."
]}

    {{!Txn}Transactions} and {{!Cursor}Iterators} are also available.
*)


(** {2 Raw bindings} *)

module Mdb :module type of Lmdb_bindings


(** {2 Common types} *)

(** Operations on sets of flags. *)
module type Flags = sig
  type t
  (** The type of a set of flags *)

  external ( + ) : t -> t -> t = "%orint"
  (** [a + b] is the {e union} of flag sets [a] and [b].
      This corresponds to a bitwise {e or} on C bitfields. *)

  external ( * ) : t -> t -> t = "%andint"
  (** [a * b] is the intersection of flag sets a and b.
      This corresponds to a bitwise {e and} on C bitfields. *)

  val test : t -> t -> bool
  (** [test a b] is [true] only if [a] is a subset of [b].
      This corresponds to [a & b == a] for C bitfields. *)

  external eq : t -> t -> bool = "%equal"
  (** [eq a b] The equals relation. *)

  val none : t
  (** [none] The empty set of flags. *)
end


(** {3 Permissions} *)

(** This library uses [[< `Read | `Write ]] phantom types to encode the
    read/write permissions of environments, transactions, dbs and
    cursors. The following values are used to request read-only or read-write
    permissions on environments, transactions and cursors.
*)

type 'a perm constraint 'a = [< `Read | `Write ]

(** Request read-only access. *)
val ro : [ `Read ] perm

(** Request read-write access. *)
val rw : [ `Read | `Write ] perm


(** {2 Database} *)

(** Collection of dbs stored in a single memory-mapped file. *)
module Env : sig
  type -'perm t constraint 'perm = [< `Read | `Write ]

  module Flags :  sig
    include Flags
    val fixed_map : t
    val no_subdir : t
      (** Create the environment not in an existing directory,
          but create the data file with exactly the filename given to {!Env.create}.
          The lock file will have "-lock" appended.
      *)

    val no_sync : t
    val no_meta_sync : t
    val write_map : t
    val map_async : t
    val no_tls : t
    val no_lock : t
    val no_read_ahead : t
    val no_mem_init : t
  end

  (** [create perm path] creates an environment with {!ro} or {!rw} permissions
      with {e data} and {e lock} files in the already existing directory [path].
      If no separate directory is desired, {!Flags.no_subdir} can be passed.

      The returned handle is not garbage collected and should be closed
      explicitely to free locks and prevent corruption on async environments.

      @param map_size Size of the memory map. Limited by the virtual address space.
      @param max_readers Maximum number of threads/reader slots.
      @param max_dbs Maximum number of named dbs.
      @param mode The UNIX permissions to set on created files and semaphores. Default is [0o755].
  *)
  val create :
    'perm perm -> ?max_readers:int -> ?map_size:int -> ?max_dbs:int ->
    ?flags:Flags.t -> ?mode:int -> string -> 'perm t



  val sync : ?force:bool -> [> `Write ] t -> unit

  val close: _ t -> unit

  val copy : ?compact:bool -> [> `Read ] t -> string -> unit

  val copyfd : ?compact:bool -> [> `Read ] t -> Unix.file_descr -> unit

  val set_flags : 'perm t -> Flags.t -> bool -> unit

  val flags : 'perm t -> Flags.t

  val set_map_size : [> `Write ] t -> int -> unit

  val path : 'perm t -> string

  val fd : 'perm t -> Unix.file_descr

  val stats : [> `Read ] t -> Mdb.stats

  val max_readers : 'perm t -> int

  val max_keysize : 'perm t -> int

  val reader_list : 'perm t -> string list

  val reader_check : 'perm t -> int

end

(** Series of operations on an environment performed atomically. *)
module Txn : sig
  (** A transaction handle. A transaction may be read-only or read-write. *)
  type -'perm t constraint 'perm = [< `Read | `Write ]

  (** [go perm env ?txn f]
      runs a transaction with [perm] read/write permissions in [env].

      The function [f txn] will receive the transaction handle. All changes to
      the environment [env] done using the transaction handle will be persisted
      to the environment only when [f] returns. After [f] returned, the
      transaction handle is invalid and should therefore not be leaked outside
      [f].

      @return [None] if the transaction was aborted with [abort], and [Some _] otherwise.
      @param txn Create a child transaction to [txn].
      This is not supported on an [env] with {!Env.Flags.write_map}.

      Here is an example incrementing a value atomically:
{[
go rw env begin fun txn ->
  let v = Db.get ~txn k in
  Db.put ~txn k (v+1) ;
  v
end
]}
  *)
  val go :
    'perm perm ->
    ?txn:'perm t ->
    'perm Env.t ->
    ('perm t -> 'a) -> 'a option



  (** [abort txn] aborts transaction [txn] and the current [go] function,
      which will return [None].
  *)
  val abort : 'perm t -> 'b

  val env : 'perm t -> 'perm Env.t
  (** [env txn] return the environment of [txn] *)

end

(** Key-value dbs. *)
module Db : sig
  (** Converters to and from the internal representation of keys and values.

      A converter is a module with Signature {!S} containing the serialising
      {!Conv.S.write} and deserialising {!Conv.S.read} functions as well as
      the {!Conv.S.flags} applied when the converter is used in a db.

      For convenience every converter is is also exported as first-class value
      so it cat be easily passed to {!Db.create} and {!Db.open_existing}.
  *)
  module Conv : sig
    (** {2 Types } *)

    type bigstring =
      (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
    (** Bigstrings are used to transfer the raw serialised data into and out of
        the database. They may point directly to a memory-mapped region of the
        database file. *)

    (** Flags describing the (sorting) properties of keys and values of a db.

        See the LMDB documentation for the meaning of these flags.

        You probably won't need those flags since the converters provided in {!
        Conv} will already make appropriate use of these flags.
    *)
    module Flags : sig
      include Flags
      val integer_key : t
      val reverse_key : t
      val integer_dup : t
      val reverse_dup : t
      val dup_fixed : t
    end

    (** Signature of a converter module *)
    module type S = sig
      type t
      val flags : Flags.t
      (** Flags to be set on a db using this converter.

          Depending on the use of a converter as {e key} or {e value}
          {!Db.create} and {!Db.open_existing} will select the correct set of
          flags: [_key] flags will be used for keys and [_dup] flags will be
          used for values on dbs supporting duplicates.
      *)

      val read : bigstring -> t
      (** [read b] deserialises the bigstring [b].

          The bigstring [b] is only valid as long as the current transaction.
          It is therefore strongly recommended not to leak [b] out of [read].
      *)

      val write : (int -> bigstring) -> t -> bigstring
      (** [write alloc x] serialises [x].

          [write] {e may} call [alloc len] {e once} to allocate a [bigstring] of size [len].
          It then {e must} fill the serialised data of [x] into this [bigstring]
          and return {e exactly this} bigstring. If [write] didn't call [alloc] it may
          return any [bigstring].

          If [write] calls [alloc] the library can utilise the [MDB_RESERVE]
          interface when appropriate to avoid calls to [malloc] and [memcpy].
      *)
    end

    (** ['a t] is a first-class converter module. *)
    type 'a t = (module S with type t = 'a)

    (** {2 Predefined converters } *)

    (** {3 Strings } *)

    val bigstring :bigstring t
    (** The [bigstring] converter returns bigstrings as returned by the lmdb
        backend. These bigstrings point into the environment memory-map and
        are therefore only guaranteed to be valid until the transaction ends.
        If you need longer-lived values use the [string] converter, make a copy
        or write a custom converter.
    *)

    val string :string t


    (** {3 Integers } *)

    (** The integer converters will make use of {! Flags.t} as
        appropriate so that integers are sorted in ascending order irrespective
        of machine endianness.
    *)

    val int32_be        :Int32.t t
    val int64_be        :Int64.t t
    val int32_le        :Int32.t t
    val int64_le        :Int64.t t

    (** For convenience the [_as_int] converters convert the internal integer
        representation to and from [int].
        @raise Invalid_argument "Lmdb: Integer truncated"
    *)

    val int32_be_as_int :int t
    val int64_be_as_int :int t
    val int32_le_as_int :int t
    val int64_le_as_int :int t

    (** {2 Underlying modules } *)

    (** These underlying modules may be useful when writing custom converters *)

    module Bigstring       :S with type t = bigstring
    module String          :S with type t = string
    module Int32_be        :S with type t = Int32.t
    module Int64_be        :S with type t = Int64.t
    module Int32_le        :S with type t = Int32.t
    module Int64_le        :S with type t = Int64.t
    module Int32_be_as_int :S with type t = int
    module Int64_be_as_int :S with type t = int
    module Int32_le_as_int :S with type t = int
    module Int64_le_as_int :S with type t = int
  end

  (** A handle for a db from keys of type ['key] to values of type ['value]. *)
  type ('key, 'value, -'perm) t
    constraint 'perm = [< `Read | `Write ]

  (** [create ~key ~value env]
      open (and possibly create) a db in the environment [env].

      Only a single transaction may call this function at a time.
      This transaction needs to finish before any other transaction may call
      this function.

      @param name if omitted the unnamed db will be opened. Otherwise make
      sure that {! Env.create} was called with a large enough [~max_dbs].
      @param key Converter for keys
      @param value Converter for values
      @raise Invalid_argument if an existing db doesn't support duplicates,
      but duplicates where requested.
  *)
  val create :
    ?dup        :bool ->
    key         :'key Conv.t ->
    value       :'value Conv.t ->
    ?txn        :[> `Read | `Write ] Txn.t ->
    ?name       :string ->
    ([> `Read | `Write ] as 'perm) Env.t -> ('key, 'value, 'perm) t

  (** [open_existing env] is like [create], but only opens already existing dbs.
      @raise Not_found if the db doesn't exist.
  *)
  val open_existing :
    ?dup        :bool ->
    key         :'key Conv.t ->
    value       :'value Conv.t ->
    ?txn        :[> `Read ] Txn.t ->
    ?name       :string ->
    ([> `Read ] as 'perm) Env.t ->
    ('key, 'value, 'perm) t

  (** [get db key] returns the first value associated to [key].
      @raise Not_found if the key is not in the db.
  *)
  val get : ('key, 'value, [> `Read ]) t -> ?txn:[> `Read ] Txn.t -> 'key -> 'value

  (** Flags usable with the [put] operation. *)
  module Flags : sig
    include Flags
    val no_overwrite : t
    (** Raise {!exception: Exists} if the key already exists no matter whether the db
        supports duplicates.
    *)

    val no_dup_data : t
    (** Only for dbs supporting duplicates: Don't add the value to an already
        existing key if this value is already part of this key.
    *)

    val append : t
    (** Add a key that is greater than any existing key.
        Used to efficiently add sorted data.
    *)

    val append_dup : t
    (** Add value to key that is greater than any existing value of this key.
        Used to efficiently add sorted values to a key.
    *)
  end

  (** [put db key value] adds [value] to [key].

      For a db not supporting duplicates an existing value is overwritten.
      For a db supporting duplicates the value is added to the key.

      @param flags {!Flags}
      @raise Exists if the key or key-value pair is already in the db and
      {! Flags.no_overwrite} or {! Flags.no_dup_data} was passed in
      [flags].
  *)
  val put : ('key, 'value, ([> `Read | `Write ] as 'perm)) t ->
    ?txn:'perm Txn.t -> ?flags:Flags.t -> 'key -> 'value -> unit

  (** [remove db key] removes [key] from [db].

      @param value Only the specified value is removed.
      If not provided, all the values of [key] and [key] itself are removed.

      @raise Not_found if the key is not in the db.
  *)
  val remove : ('key, 'value, ([> `Read | `Write ] as 'perm)) t ->
    ?txn:'perm Txn.t -> ?value:'value -> 'key -> unit


  (** {2 Misc} *)

  val stats : ?txn: [> `Read ] Txn.t -> ('key, 'value, [> `Read ]) t -> Mdb.stats

  (** [drop ?delete db] Empties [db].
      @param delete If [true] [db] is also deleted from the environment
      and the handle [db] invalidated. *)
  val drop : ?txn: ([> `Read | `Write ] as 'perm) Txn.t -> ?delete:bool ->
    ('key, 'value, 'perm) t -> unit

  (** [compare_key db ?txn a b]
     Compares [a] and [b] as if they were keys in [db]. *)
  val compare_key : ('key, 'value, [> `Read ]) t -> ?txn:[> `Read ] Txn.t -> 'key -> 'key -> int

  (** [compare db ?txn a b] Same as [compare_key]. *)
  val compare : ('key, 'value, [> `Read ]) t -> ?txn:[> `Read ] Txn.t -> 'key -> 'key -> int

  (** [compare_val db ?txn a b]
     Compares [a] and [b] as if they were values in a [dup_sort] [db]. *)
  val compare_val : ('key, 'value, [> `Read ]) t -> ?txn:[> `Read ] Txn.t -> 'value -> 'value -> int
end

(** Iterators over dbs. *)
module Cursor : sig
  (** A cursor allows to iterate manually on the db.
      Every cursor implicitely uses a transaction.
  *)

  type ('key, 'value, -'perm) t
    constraint 'perm = [< `Read | `Write ]

  (** [go perm db ?txn f] makes a cursor in the transaction [txn] using the
      function [f cursor].

      The function [f] will receive the [cursor].
      A cursor can only be created and used inside a transaction.
      The cursor inherits the permissions of the transaction.
      The cursor should not be leaked outside of [f].

      Here is an example that returns the first 5 elements of a [db]:
      {[
go ro db begin fun c ->
let h = first c in
let rec aux i =
  if i < 5 then next c :: aux (i+1)
  else []
in
h :: aux 1
end
      ]}

      @param txn if omitted a transient transaction will implicitely be
      created before calling [f] and be committed after [f] returns.
      Such a transient transaction may be aborted using {! abort}.
  *)
  val go : 'perm perm -> ?txn:'perm Txn.t -> ('key, 'value, 'perm) Db.t ->
    (('key, 'value, 'perm) t -> 'a) -> 'a option

  (** [abort cursor] aborts [cursor] and the current [go] function,
      which will return [None].
      @raise Invalid_argument if a transaction [~txn] was passed to the [go]
      function.
  *)
  val abort : _ t -> unit


  (** {2 Modification} *)

  (** {!Db.Flags} *)
  module Flags : module type of Db.Flags

  (** [put cursor key value] adds [value] to [key] and moves the cursor to
      its position.

      For a db not supporting duplicates an existing value is overwritten.
      For a db supporting duplicates the value is added to the key.

      @param flags {!Flags}
      @raise Exists if the key or key-value pair is already in the db and
      {! Db.Flags.no_overwrite} or {! Db.Flags.no_dup_data} was passed in
      [flags].
  *)
  val put : ('key, 'value, [> `Read | `Write ]) t ->
    ?flags:Flags.t -> 'key -> 'value -> unit

  (** [replace cursor value] replace the current value by [value]. *)
  val replace : ('key, 'value, [> `Read | `Write ]) t -> 'value -> unit

  (** [remove cursor] removes the current binding.
      @param all If [true] removes all the bindings associated to the current key.
      Default is [false].
  *)
  val remove : ?all:bool -> ('key, 'value, [> `Read | `Write ]) t -> unit


  (** {2 Reading} *)

  (** [current cursor] returns key and value at the position of the cursor. *)
  val current     : ('key, 'value, [> `Read ]) t -> 'key * 'value

  (** [count cursor] returns the number of values bound to the current key. *)
  val count : ('key, 'value, [> `Read ]) t -> int


  (** {3 Seeking} *)

  (** [get cursor key] moves the cursor to the {e first} value of [key]. *)
  val get : ('key, 'value, [> `Read ]) t -> 'key -> 'value

  (** [seek cursor key] moves the cursor to the first value of [key]. *)
  val seek        : ('key, 'value, [> `Read ]) t -> 'key -> 'key * 'value

  (** [seek_range cursor key] moves the cursor to the {e first} value of the
      first key greater than or equal to [key].
  *)
  val seek_range     : ('key, 'value, [> `Read ]) t -> 'key -> 'key * 'value

  (** [seek_dup cursor key value] moves the cursor to [value] of [key]. *)
  val seek_dup : ('key, 'value, [> `Read ]) t ->
    'key -> 'value -> unit

  (** [seek_range_dup cursor key value] moves the cursor to the first value greater
      than or equal to [value] of the first key greater than or equal to [key].
  *)
  val seek_range_dup : ('key, 'value, [> `Read ]) t ->
    'key -> 'value -> ('key * 'value)


  (** {3 Moving} *)

  (** [first cursor] moves the cursor to the {e first} value of the first key. *)
  val first       : ('key, 'value, [> `Read ]) t -> 'key * 'value

  (** [first_dup cursor] moves the cursor to the first {e value} of the current key. *)
  val first_dup : ('key, 'value, [> `Read ]) t -> 'value

  (** [last cursor] moves the cursor to the {e last} value of the last key. *)
  val last        : ('key, 'value, [> `Read ]) t -> 'key * 'value

  (** [last_dup cursor] moves the cursor to the last {e value} of the current key. *)
  val last_dup : ('key, 'value, [> `Read ]) t -> 'value

  (** [next cursor] moves the cursor to the next key-value pair.
      This may be the {e next value} of the {e current key} or the
      {e first value} of the {e next key}.
  *)
  val next        : ('key, 'value, [> `Read ]) t -> 'key * 'value

  (** [next_nodup cursor]
      moves the cursor to the {e first} value of the next key.
  *)
  val next_nodup  : ('key, 'value, [> `Read ]) t -> 'key * 'value

  (** [next_dup cursor] moves the cursor to the next value of the current key.
      @raise Not_found if the cursor is already on the last value of the current key.
  *)
  val next_dup : ('key, 'value, [> `Read ]) t -> 'value

  (** [prev cursor] moves the cursor to the previous key-value pair.
      This may be the {e previous value} of the {e current key} or the
      {e last value} of the {e previous key}.
  *)
  val prev        : ('key, 'value, [> `Read ]) t -> 'key * 'value

  (** [prev_nodup cursor]
      moves the cursor to the {e last} value of the previous key.
  *)
  val prev_nodup  : ('key, 'value, [> `Read ]) t -> 'key * 'value

  (** [prev_dup cursor] moves the cursor to the previous value of the current key.
      @raise Not_found if the cursor is already on the first value of the current key.
  *)
  val prev_dup : ('key, 'value, [> `Read ]) t -> 'value
end


(** {2 Error reporting} *)

exception Exists
(** Raised when adding already existing key or key-value pair to a db with
    {! Db.Flags.no_overwrite} or {! Db.Flags.no_dup_data}
    or when trying to [put ~flags:Flags.append(_dup)] non-sorted data.
*)

exception Not_found
(** Raised when searching for non-existing key *)

exception Error of int
(** Other errors are reported with [Invalid_arg s] or [Error n]. *)

val pp_error : Format.formatter -> int -> unit
(** [pp_error Format.std_formatter e] prepares a human-readable description
    of the given error code [n] raised via [Error n].
*)

val version : string * int * int * int
(** [(name, major, minor, patch)] *)
