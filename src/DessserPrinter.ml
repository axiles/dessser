open Batteries

open DessserTools
open DessserMiscTypes
module T = DessserTypes

type context = Declaration | Definition

type t =
  { context : context ;
    def : string IO.output ;
    mutable decls : string list ;
    mutable defs : string list ;
    mutable indent : string ;
    (* The set of all type ids that have already been declared *)
    mutable declared : Set.String.t ;
    mutable external_types : (string * (t -> backend_id -> string)) list }

let make ?(declared=Set.String.empty) ?(decls=[]) context external_types =
  { context ;
    def = IO.output_string () ;
    decls ;
    defs = [] ;
    indent = "" ;
    declared ;
    external_types }

let new_top_level p f =
  let p' = make ~declared:p.declared ~decls:p.decls
                p.context p.external_types in
  let res = f p' in
  (* Merge the new defs and decls into old decls and defs: *)
  p.defs <- IO.close_out p'.def :: List.rev_append p'.defs p.defs ;
  p.decls <- p'.decls ;
  p.declared <- Set.String.union p.declared p'.declared ;
  p.external_types <- assoc_merge p.external_types p'.external_types ;
  res

let indent_more p f =
  let indent = p.indent in
  p.indent <- p.indent ^"  " ;
  finally (fun () -> p.indent <- indent)
    f ()

(* Call [f] to output a new declaration: *)
let new_declaration p f =
  (* Write in a temp string to avoid being interrupted by another
   * declaration: *)
  let oc = IO.output_string ()
  and indent = p.indent in
  p.indent <- "" ;
  f oc ;
  p.indent <- indent ;
  IO.close_out oc

(* Add the declaration output by [f] before every currently emitted
 * declarations: *)
let prepend_declaration p f =
  p.decls <- new_declaration p f :: p.decls

(* If [t] has not been declared yet then call [f] that's supposed to emit
 * its declaration (as a type identified by passed identifier). The resulting
 * string is added to declarations.
 * If [t] has already been declared just return its identifier.
 * The "identifier" may not be valid for a given back-end and might need further
 * adaptation. *)
let declared_type p t f =
  (* For the purpose of identifying types, use a generic type name "_": *)
  let s = new_declaration p (fun oc -> f oc "_") in
  let id =
    let t = T.shrink t in
    match List.find (fun (_n, t') -> T.eq t t') !T.these with
    | exception Not_found -> "t"^ Digest.to_hex (Digest.string s)
    | n, _ -> n in
  if Set.String.mem id p.declared then id
  else (
    let s = new_declaration p (fun oc -> f oc id) in
    p.declared <- Set.String.add id p.declared ;
    p.decls <- s :: p.decls ;
    id
  )

(* Return either the result of [declared_type p t f] or [s] depending on
 * whether a explicit type name has been set for this type.
 * in case [declared_type] is called, the identifier returned need to be
 * validated by the back-end, whereas [s] might not be an identifier and thus
 * need no such validation. The returned boolean helps to distinguish between
 * those two cases. *)
let declare_if_named p t s f =
  if List.exists (fun (_n, t') -> T.eq t' t) !T.these
  then true, declared_type p t f
  else false, s

let get_external_type p name backend_id =
  match List.assoc name p.external_types with
  | exception (Not_found as e) ->
      Printf.eprintf "Unknown external type %S!\n" name ;
      raise e (* reraise *)
  | f ->
      f p backend_id
