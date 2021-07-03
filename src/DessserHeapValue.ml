(* Dessser API is optimised to convert from one format into another without
 * materializing complex values in memory.
 * But when we do want to materialize the value in the heap, another API is
 * more natural.
 * The two following modules are designed to unserialize into a materialized
 * values and to then serialize that materialized value. *)
open Batteries
open Stdint
open Dessser
open DessserTools
module E = DessserExpressions
module Mask = DessserMasks
module StdLib = DessserStdLib
module T = DessserTypes
open E.Ops

(* The generated code can use a runtime fieldmask or just encode everything.
 * Of course, we could define a function A that calls the runtime mask version
 * of some other function B with a constant copy-field mask, and the partial
 * evaluation would inline B in A, removing all the code dealing with the
 * fieldmask, as long as B is not recursive. Also, it would not inline
 * externally defined functions that might be called by B. So it's more
 * efficient to have two versions of B: one that accept a runtime fieldmask
 * and one that does not. *)
type fieldmask = CompTimeMask | RunTimeMask of E.t

let fieldmask_get i = function
  | CompTimeMask -> CompTimeMask
  | RunTimeMask ma -> RunTimeMask (mask_get i ma)

let fieldmask_copy = function
  | CompTimeMask -> CompTimeMask
  | RunTimeMask _ -> RunTimeMask copy_field

module type MATERIALIZE =
sig
  module Des : DES

  (* TODO: This should also accept a runtime fieldmask as parameter. *)

  val make : ?config:Des.config ->
             T.mn ->
             E.env ->
             E.t (* src -> e*src *)
end

module Materialize (Des : DES) :
  MATERIALIZE with module Des = Des =
struct
  module Des = Des

  let rec dvec dim mn dstate mn0 path l src =
    let src = Des.vec_opn dstate mn0 path dim mn l src in
    let rec loop ids i l src =
      if i >= dim then
        make_pair
          (make_vec (List.rev ids))
          (Des.vec_cls dstate mn0 path l src)
      else
        let src = if i = 0 then src else
                    Des.vec_sep dstate mn0 path l src in
        let subpath = Path.(append (CompTime i) path) in
        let v_src = make1 dstate mn0 subpath mn l src in
        E.with_sploded_pair ~l "dvec" v_src (fun l v src ->
          loop (v :: ids) (i + 1) l src) in
    loop [] 0 l src

  (* Lists and sets are serialized the same, so here the list is desserialized
   * into an slist, and then the final operation converts it into a list or a
   * set: *)

  and dlist mn dstate mn0 path l src =
    dslist list_of_slist_rev mn dstate mn0 path l src

  and dset mn dstate mn0 path l src =
    dslist set_of_slist mn dstate mn0 path l src

  and dslist of_slist mn dstate mn0 path l src =
    match Des.list_opn dstate with
    | KnownSize list_opn ->
        let dim_src = list_opn mn0 path mn l src in
        let inits_src =
          E.with_sploded_pair ~l "dslist1" dim_src (fun l dim src ->
            let inits_src_ref = make_ref (make_pair (end_of_list mn) src) in
            let_ ~name:"inits_src_ref" ~l inits_src_ref (fun l inits_src_ref ->
              let inits_src = get_ref inits_src_ref in
              seq [
                StdLib.repeat ~l ~from:(i32 0l) ~to_:(to_i32 dim) (fun l n ->
                  E.with_sploded_pair ~l "dslist2" inits_src (fun l inits src ->
                    let src =
                      if_ (eq n (i32 0l))
                        ~then_:src
                        ~else_:(Des.list_sep dstate mn0 path l src) in
                    let subpath = Path.(append (RunTime n) path) in
                    let v_src = make1 dstate mn0 subpath mn l src in
                    E.with_sploded_pair ~l "dslist3" v_src (fun _l v src ->
                      make_pair (cons v inits) src) |>
                    set_ref inits_src_ref)) ;
                inits_src ])) in
        E.with_sploded_pair ~l "dslist4" inits_src (fun l inits src ->
          let v = of_slist inits
          and src = Des.list_cls dstate mn0 path l src in
          make_pair v src)
    | UnknownSize (list_opn, is_end_of_list) ->
        let src = list_opn mn0 path mn l src in
        let_ ~name:"inits_ref" ~l (make_ref (end_of_list mn)) (fun l inits_ref ->
          let_ ~name:"src_ref" ~l (make_ref src) (fun l src_ref ->
            let_ ~name:"n_ref" ~l (make_ref (u32_of_int 0)) (fun l n_ref ->
              seq [
                while_ (not_ (is_end_of_list mn0 path l (get_ref src_ref))) (
                  let src = get_ref src_ref
                  and n = get_ref n_ref
                  and inits = get_ref inits_ref in
                  let subpath = Path.(append (RunTime n) path) in
                  let src =
                    if_ (eq n (u32_of_int 0))
                      ~then_:src
                      ~else_:(Des.list_sep dstate mn0 subpath l src) in
                  let v_src = make1 dstate mn0 subpath mn l src in
                  E.with_sploded_pair ~l "dlist7" v_src (fun _l v src ->
                    seq [
                      set_ref inits_ref (cons v inits) ;
                      set_ref src_ref src ;
                      set_ref n_ref (add n (u32_of_int 1)) ])) ;
                (
                  let v = of_slist (get_ref inits_ref)
                  and src = Des.list_cls dstate mn0 path l (get_ref src_ref) in
                  make_pair v src
                ) ])))

  and dtup mns dstate mn0 path l src =
    let src = Des.tup_opn dstate mn0 path mns l src in
    let rec loop ids i l src =
      if i >= Array.length mns then
        make_pair
          (make_tup (List.rev ids))
          (Des.tup_cls dstate mn0 path l src)
      else
        let src = if i = 0 then src else
                    Des.tup_sep dstate mn0 path l src in
        let subpath = Path.(append (CompTime i) path) in
        let v_src = make1 dstate mn0 subpath mns.(i) l src in
        E.with_sploded_pair ~l "dtup" v_src (fun l v src ->
          loop (v :: ids) (i + 1) l src) in
    loop [] 0 l src

  and drec mns dstate mn0 path l src =
    let src = Des.rec_opn dstate mn0 path mns l src in
    let len = Array.length mns in
    let rec loop ids i l src =
      if i >= len then
        make_pair
          (make_rec (List.mapi (fun i id ->
             fst mns.(len - i - 1), id) ids))
          (Des.rec_cls dstate mn0 path l src)
      else
        let src = if i = 0 then src else
                    Des.rec_sep dstate mn0 path l src in
        let subpath = Path.(append (CompTime i) path) in
        let v_src = make1 dstate mn0 subpath (snd mns.(i)) l src in
        E.with_sploded_pair ~l "drec" v_src (fun l v src ->
          loop (v :: ids) (i + 1) l src) in
    loop [] 0 l src

  and dsum mns dstate mn0 path l src =
    let cstr_src = Des.sum_opn dstate mn0 path mns l src in
    let max_lbl = Array.length mns - 1 in
    E.with_sploded_pair ~l "dsum1" cstr_src (fun l cstr src ->
      let rec choose_cstr i =
        assert (i <= max_lbl) ;
        let res () =
          let subpath = Path.(append (CompTime i) path) in
          let _, subtyp = mns.(i) in
          let v_src = make1 dstate mn0 subpath subtyp l src in
          E.with_sploded_pair ~l "dsum2" v_src (fun l v src ->
            make_pair
              (construct mns i v)
              (Des.sum_cls dstate mn0 path l src))
        in
        if i = max_lbl then
          seq [
            assert_ (eq cstr (u16 (Uint16.of_int max_lbl))) ;
            res () ]
        else
          if_ (eq (u16 (Uint16.of_int i)) cstr)
            ~then_:(res ())
            ~else_:(choose_cstr (i + 1)) in
      choose_cstr 0)

  and dvoid _ _ _ _ src =
    make_pair void src

  and dext name _dstate _mn0 _path _l src =
    apply (type_method name (E.DesNoMask Des.id)) [ src ]

  and dthis _dstate mn0 _path _l src =
    (* Call ourself recursively *)
    apply (myself T.(pair mn0 ptr)) [ src ]

  and make1 dstate mn0 path mn l src =
    let rec des_of_vt = function
      | T.This -> dthis
      | T.Ext n -> dext n
      | T.Void -> dvoid
      | T.Base Float -> Des.dfloat
      | T.Base String -> Des.dstring
      | T.Base Bool -> Des.dbool
      | T.Base Char -> Des.dchar
      | T.Base I8 -> Des.di8
      | T.Base I16 -> Des.di16
      | T.Base I24 -> Des.di24
      | T.Base I32 -> Des.di32
      | T.Base I40 -> Des.di40
      | T.Base I48 -> Des.di48
      | T.Base I56 -> Des.di56
      | T.Base I64 -> Des.di64
      | T.Base I128 -> Des.di128
      | T.Base U8 -> Des.du8
      | T.Base U16 -> Des.du16
      | T.Base U24 -> Des.du24
      | T.Base U32 -> Des.du32
      | T.Base U40 -> Des.du40
      | T.Base U48 -> Des.du48
      | T.Base U56 -> Des.du56
      | T.Base U64 -> Des.du64
      | T.Base U128 -> Des.du128
      | T.Usr vt ->
          (* Deserialize according to vt.def, then make a new user value to
           * keep the user type: *)
          fun state mn0 path l ptr ->
            let v_src = des_of_vt vt.def state mn0 path l ptr in
            E.with_sploded_pair ~l "des_usr_type" v_src (fun _l v src ->
              make_pair (make_usr vt.name [ v ]) src)
      | T.Tup mns -> dtup mns
      | T.Rec mns -> drec mns
      | T.Sum mns -> dsum mns
      | T.Vec (dim, mn) -> dvec dim mn
      | T.Lst mn -> dlist mn
      | T.Set (Simple, mn) -> dset mn
      | T.Set _ -> todo "Materialization of non simple sets"
      | T.Map _ -> assert false (* No value of map type *)
      | _ -> invalid_arg "make1"
    in
    let vt = mn.typ in
    if mn.nullable then (
      if_ (Des.is_null dstate mn0 path l src)
        ~then_:(make_pair (null vt) (Des.dnull vt dstate mn0 path l src))
        ~else_:(
          let src = Des.dnotnull vt dstate mn0 path l src in
          let des = des_of_vt vt in
          let v_src = des dstate mn0 path l src in
          E.with_sploded_pair ~l "make1_1" v_src (fun _l v src ->
            make_pair (not_null v) src))
    ) else (
      let des = des_of_vt vt in
      des dstate mn0 path l src
    )

  let make ?config mn0 l =
    E.func1 ~l T.ptr (fun l src ->
      let dstate, src = Des.start ?config mn0 l src in
      E.with_sploded_pair ~l "make" (make1 dstate mn0 [] mn0 l src) (fun l v src ->
        make_pair v (Des.stop dstate l src)))
end

(* The other way around: given a heap value of some type and a serializer,
 * serialize that value.
 * The generated function will optionally accept a runtime fieldmask. *)

module type SERIALIZE =
sig
  module Ser : SER

  val serialize :
    ?config:Ser.config ->
    ?with_fieldmask:bool ->
    T.mn ->
    E.env ->
    E.t (* mask (if with_fieldmask) -> value -> dataptr -> dataptr *)

  val sersize :
    ?config:Ser.config ->
    ?with_fieldmask:bool ->
    T.mn ->
    E.env ->
    E.t (* mask (if with_fieldmask) -> v -> size *)
end

module Serialize (Ser : SER) :
  SERIALIZE with module Ser = Ser =
struct
  module Ser = Ser

  let rec svec dim mn ma sstate mn0 path l v dst =
    let dst = Ser.vec_opn sstate mn0 path dim mn l dst in
    let rec loop i l dst =
      let subpath = Path.(append (CompTime i) path) in
      if i >= dim then
        Ser.vec_cls sstate mn0 path l dst
      else
        let dst = if i = 0 then dst else
                    Ser.vec_sep sstate mn0 subpath l dst in
        let_ ~name:"svec_dst" ~l dst (fun l dst ->
          let v' = nth (u32_of_int i) v in
          (* From now on we copy all fields, as individual vector items cannot
           * be filtered: (TODO: why not BTW?) *)
          let ma = fieldmask_copy ma in
          ser1 sstate mn0 subpath mn l v' ma dst |>
          loop (i + 1) l) in
    loop 0 l dst

  and slist_or_set mn ma sstate mn0 path l v dst =
    let len = cardinality v in
    let dst = Ser.list_opn sstate mn0 path mn (Some len) l dst in
    let_ ~name:"dst_ref" ~l (make_ref dst) (fun l dst_ref ->
      let dst = get_ref dst_ref in
      let_ ~name:"n_ref" ~l (make_ref (i32 0l)) (fun l n_ref ->
        let n = get_ref n_ref in
        seq [
          for_each  ~name:"x" ~l v (fun l x ->
            let subpath = Path.(append (RunTime n) path) in
            let dst =
              if_ (gt n (i32 0l))
                ~then_:(Ser.list_sep sstate mn0 subpath l dst)
                ~else_:dst in
            (* From now on copy everything, as individual list items cannot
             * be selected - since lists are variable in length *)
            let ma = fieldmask_copy ma in
            seq [
              set_ref dst_ref (ser1 sstate mn0 subpath mn l x ma dst) ;
              set_ref n_ref (add (i32 1l) n) ]) ;
          Ser.list_cls sstate mn0 path l dst ]))

  and stup mns ma sstate mn0 path l v dst =
    let dst = Ser.tup_opn sstate mn0 path mns l dst in
    let dst =
      Array.fold_lefti (fun dst i mn ->
        let subpath = Path.(append (CompTime i) path) in
        let_ ~name:"stup_dst" ~l
          (if i = 0 then dst else
                    Ser.tup_sep sstate mn0 subpath l dst)
          (fun l dst ->
            let ma = fieldmask_get i ma in
            ser1 sstate mn0 subpath mn l (get_item i v) ma dst)
      ) dst mns in
    Ser.tup_cls sstate mn0 path l dst

  and srec mns ma sstate mn0 path l v dst =
    let dst = Ser.rec_opn sstate mn0 path mns l dst in
    let dst =
      Array.fold_lefti (fun dst i (fname, mn) ->
        let subpath = Path.(append (CompTime i) path) in
        let_ ~name:"srec_dst" ~l
          (if i = 0 then dst else
                    Ser.rec_sep sstate mn0 subpath l dst)
          (fun l dst ->
            let ma = fieldmask_get i ma in
            comment ("serialize field "^ fname)
                    (ser1 sstate mn0 subpath mn l (get_field fname v) ma dst))
      ) dst mns in
    Ser.rec_cls sstate mn0 path l dst

  (* Regarding masks, sum types are like scalars: all or nothing.
   * Indeed, the mask would have to be aware of the constructor to be
   * meaningful. *)
  and ssum mns ma sstate mn0 path l v dst =
    let max_lbl = Array.length mns - 1 in
    let dst =
      let_ ~name:"label1" ~l
        (label_of v)
        (fun l label ->
          let_ ~name:"ssum_dst" ~l
            (Ser.sum_opn sstate mn0 path mns l label dst)
            (fun l dst ->
              let rec choose_cstr i =
                let subpath = Path.(append (CompTime i) path) in
                assert (i <= max_lbl) ;
                let field, mn = mns.(i) in
                let v' = get_alt field v in
                if i = max_lbl then
                  seq [
                    assert_ (eq label (u16 (Uint16.of_int max_lbl))) ;
                    ser1 sstate mn0 subpath mn l v' ma dst ]
                else
                  if_ (eq (u16 (Uint16.of_int i)) label)
                    ~then_:(ser1 sstate mn0 subpath mn l v' ma dst)
                    ~else_:(choose_cstr (i + 1)) in
              choose_cstr 0)) in
    Ser.sum_cls sstate mn0 path l dst

  and svoid _ _ _ _ _ dst = dst

  and sext name ma _sstate _mn0 _path _l v dst =
    match ma with
    | RunTimeMask ma ->
        apply (type_method name (E.SerWithMask Ser.id)) [ ma ; v ; dst ]
    | CompTimeMask ->
        apply (type_method name (E.SerNoMask Ser.id)) [ v ; dst ]

  and sthis ma _sstate _mn0 _path _l v dst =
    (* Call ourself recursively *)
    match ma with
    | RunTimeMask ma ->
        apply (myself T.ptr) [ ma ; v ; dst ]
    | CompTimeMask ->
        apply (myself T.ptr) [ v ; dst ]

  and ser1 sstate mn0 path mn l v ma dst =
    let rec ser_of_vt = function
      | T.This -> sthis ma
      | T.Ext n -> sext n ma
      | T.Void -> svoid
      | T.Base Float -> Ser.sfloat
      | T.Base String -> Ser.sstring
      | T.Base Bool -> Ser.sbool
      | T.Base Char -> Ser.schar
      | T.Base I8 -> Ser.si8
      | T.Base I16 -> Ser.si16
      | T.Base I24 -> Ser.si24
      | T.Base I32 -> Ser.si32
      | T.Base I40 -> Ser.si40
      | T.Base I48 -> Ser.si48
      | T.Base I56 -> Ser.si56
      | T.Base I64 -> Ser.si64
      | T.Base I128 -> Ser.si128
      | T.Base U8 -> Ser.su8
      | T.Base U16 -> Ser.su16
      | T.Base U24 -> Ser.su24
      | T.Base U32 -> Ser.su32
      | T.Base U40 -> Ser.su40
      | T.Base U48 -> Ser.su48
      | T.Base U56 -> Ser.su56
      | T.Base U64 -> Ser.su64
      | T.Base U128 -> Ser.su128
      | T.Usr vt -> ser_of_vt vt.def
      | T.Tup mns -> stup mns ma
      | T.Rec mns -> srec mns ma
      | T.Sum mns -> ssum mns ma
      | T.Vec (dim, mn) -> svec dim mn ma
      (* Thanks to cardinality and fold being generic, lists and sets are
       * serialized the same: *)
      | T.Lst mn -> slist_or_set mn ma
      | T.Set (_, mn) -> slist_or_set mn ma
      | T.Map _ -> assert false (* No value of map type *)
      | _ -> invalid_arg "ser1" in
    let on_copy =
      (* Copy or Recurse are handled the same: *)
      let vt = mn.typ in
      if mn.nullable then
        if_null v
          ~then_:(Ser.snull vt sstate mn0 path l dst)
          ~else_:(
            let dst = Ser.snotnull vt sstate mn0 path l dst in
            let ser = ser_of_vt vt in
            ser sstate mn0 path l (force v) dst)
      else
        let ser = ser_of_vt vt in
        ser sstate mn0 path l v dst
    in
    match ma with
    | RunTimeMask ma ->
        if_ (eq ma skip_field)
          ~then_:dst
          ~else_:(
            if_ (eq ma set_field_null)
              ~then_: (
                if mn.nullable then
                  Ser.snull mn.typ sstate mn0 path l dst
                else (* Mask has been type checked *)
                  seq [ assert_ false_ ; dst ])
              ~else_:on_copy)
    | CompTimeMask ->
        on_copy

  (* [l] may contain serializers for external types *)
  and serialize ?config ?(with_fieldmask=true) mn0 l =
    if with_fieldmask then
      E.func3 ~l T.mask mn0 T.ptr (fun l ma v dst ->
        let path = [] in
        let sstate, dst = Ser.start ?config mn0 l dst in
        let dst = ser1 sstate mn0 path mn0 l v (RunTimeMask ma) dst in
        Ser.stop sstate l dst)
    else
      E.func2 ~l mn0 T.ptr (fun l v dst ->
        let path = [] in
        let sstate, dst = Ser.start ?config mn0 l dst in
        let dst = ser1 sstate mn0 path mn0 l v CompTimeMask dst in
        Ser.stop sstate l dst)

  (*
   * Compute the sersize of a expression:
   *)

  let rec ssvec dim mn ma mn0 path l v sz =
    let sz =
      Ser.ssize_of_vec mn0 path l v |> add sz in
    let rec loop l sz i =
      if i >= dim then sz else
      let subpath = Path.(append (CompTime i) path) in
      let v' = nth (u32_of_int i) v in
      let_ ~name:"sz" ~l sz (fun l sz ->
        let ma = fieldmask_copy ma in
        let sz = sersz1 mn mn0 subpath l v' ma sz in
        loop l sz (i + 1)) in
    loop l sz 0

  and sslist mn ma mn0 path l v sz =
    let sz =
      Ser.ssize_of_list mn0 path l v |> add sz in
    let_ ~name:"sz_ref" ~l (make_ref sz) (fun l sz_ref ->
      let sz = get_ref sz_ref in
      let len = cardinality v in
      seq [
        StdLib.repeat ~l ~from:(i32 0l) ~to_:(to_i32 len) (fun l n ->
          let v' = nth n v in
          let subpath = Path.(append (RunTime n) path) in
          let ma = fieldmask_copy ma in
          sersz1 mn mn0 subpath l v' ma sz |>
          set_ref sz_ref) ;
        sz ])

  and sstup mns ma mn0 path l v sz =
    let sz =
      Ser.ssize_of_tup mn0 path l v |> add sz in
    Array.fold_lefti (fun sz i mn ->
      let v' = get_item i v in
      let ma = fieldmask_get i ma in
      let subpath = Path.(append (CompTime i) path) in
      let_ ~name:"sz" ~l sz (fun l sz ->
        sersz1 mn mn0 subpath l v' ma sz)
    ) sz mns

  and ssrec mns ma mn0 path l v sz =
    let sz =
      Ser.ssize_of_rec mn0 path l v |> add sz in
    Array.fold_lefti (fun sz i (fname, mn) ->
      let v' = get_field fname v in
      let ma = fieldmask_get i ma in
      let subpath = Path.(append (CompTime i) path) in
      let_ ~name:"sz" ~l sz (fun l sz ->
        comment ("sersize of field "^ fname)
                (sersz1 mn mn0 subpath l v' ma sz))
    ) sz mns

  and sssum mns ma mn0 path l v sz =
    let sz =
      Ser.ssize_of_sum mn0 path l v |> add sz in
    let max_lbl = Array.length mns - 1 in
    let_ ~name:"label2" ~l
      (label_of v)
      (fun l label ->
        let rec choose_cstr i =
          let name, mn = mns.(i) in
          let v' = get_alt name v in
          let subpath = Path.(append (CompTime i) path) in
          assert (i <= max_lbl) ;
          (* From now on copy everything as individual elements an not be
           * cherry picked, since the actual type is unknown: *)
          let ma = fieldmask_copy ma in
          if i = max_lbl then
            seq [
              assert_ (eq label (u16 (Uint16.of_int max_lbl))) ;
              sersz1 mn mn0 subpath l v' ma sz ]
          else
            if_ (eq (u16 (Uint16.of_int i)) label)
              ~then_:(sersz1 mn mn0 subpath l v' ma sz)
              ~else_:(choose_cstr (i + 1)) in
        choose_cstr 0)

  and ssvoid _ _ _ _ sz = sz

  and ssext name ma _ _ _ v =
    match ma with
    | RunTimeMask ma ->
        apply (type_method name (E.SSizeWithMask Ser.id)) [ ma ; v ]
    | CompTimeMask ->
        apply (type_method name (E.SSizeNoMask Ser.id)) [ v ]

  and ssthis ma _mn0 _path _l v =
    (* Call ourself recursively *)
    match ma with
    | RunTimeMask ma ->
        apply (myself T.size) [ ma ; v ]
    | CompTimeMask ->
        apply (myself T.size) [ v ]

  and sersz1 mn mn0 path l v ma sz =
    let cumul ssizer mn0 path l v sz =
      add sz (ssizer mn0 path l v) in
    let rec ssz_of_vt = function
      | T.This -> cumul (ssthis ma)
      | T.Ext n -> cumul (ssext n ma)
      | T.Void -> ssvoid
      | T.Base Float -> cumul Ser.ssize_of_float
      | T.Base String -> cumul Ser.ssize_of_string
      | T.Base Bool -> cumul Ser.ssize_of_bool
      | T.Base Char -> cumul Ser.ssize_of_char
      | T.Base I8 -> cumul Ser.ssize_of_i8
      | T.Base I16 -> cumul Ser.ssize_of_i16
      | T.Base I24 -> cumul Ser.ssize_of_i24
      | T.Base I32 -> cumul Ser.ssize_of_i32
      | T.Base I40 -> cumul Ser.ssize_of_i40
      | T.Base I48 -> cumul Ser.ssize_of_i48
      | T.Base I56 -> cumul Ser.ssize_of_i56
      | T.Base I64 -> cumul Ser.ssize_of_i64
      | T.Base I128 -> cumul Ser.ssize_of_i128
      | T.Base U8 -> cumul Ser.ssize_of_u8
      | T.Base U16 -> cumul Ser.ssize_of_u16
      | T.Base U24 -> cumul Ser.ssize_of_u24
      | T.Base U32 -> cumul Ser.ssize_of_u32
      | T.Base U40 -> cumul Ser.ssize_of_u40
      | T.Base U48 -> cumul Ser.ssize_of_u48
      | T.Base U56 -> cumul Ser.ssize_of_u56
      | T.Base U64 -> cumul Ser.ssize_of_u64
      | T.Base U128 -> cumul Ser.ssize_of_u128
      | T.Usr vt -> ssz_of_vt vt.def
      | T.Vec (dim, mn) -> ssvec dim mn ma
      | T.Tup mns -> sstup mns ma
      | T.Rec mns -> ssrec mns ma
      | T.Sum mns -> sssum mns ma
      | T.Lst mn -> sslist mn ma
      (* Sets are serialized like lists: *)
      | T.Set (_, mn) -> sslist mn ma
      | T.Map _ -> assert false (* No value of map type *)
      | _ -> invalid_arg "sersz1" in
    let on_copy =
      let vt = mn.typ in
      if mn.nullable then
        if_null v
          ~then_:(add sz (Ser.ssize_of_null mn0 path))
          ~else_:(ssz_of_vt vt mn0 path l (force v) sz)
      else
        ssz_of_vt vt mn0 path l v sz
    in
    match ma with
    | RunTimeMask ma ->
        if_ (eq ma skip_field)
          ~then_:sz
          ~else_:(
            if_ (eq ma set_field_null)
              ~then_:(
                if mn.nullable then
                  add sz (Ser.ssize_of_null mn0 path)
                else
                  seq [ assert_ false_ ; sz ])
              ~else_:on_copy)
    | CompTimeMask ->
        on_copy

  let sersize ?config ?(with_fieldmask=true) mn l =
    if with_fieldmask then
      E.func2 ~l T.mask mn (fun l ma v ->
        let sz = Ser.ssize_start ?config mn in
        sersz1 mn mn [] l v (RunTimeMask ma) sz)
    else
      E.func1 ~l mn (fun l v ->
        let sz = Ser.ssize_start ?config mn in
        sersz1 mn mn [] l v CompTimeMask sz)
end
