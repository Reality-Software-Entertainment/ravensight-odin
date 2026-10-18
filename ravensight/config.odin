package ravensight

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

Remote_Config :: struct {
 document: json.Value,
 etag: string,
 generation: int,
 pending: bool,
 loaded: bool,
}

config_path :: proc(cl: ^Client) -> string {
 if len(cl.storage_path)==0 || len(cl.playtest.token)>0 { return "" }
 scope, _ := json.marshal([5]string{cl.api_url, cl.ingest_key, cl.device_id, cl.platform, cl.game_version}, allocator=context.temp_allocator)
 ctx: sha2.Context_256
 sha2.init_256(&ctx); sha2.update(&ctx, scope)
 digest: [32]u8
 sha2.final(&ctx, digest[:])
 b := strings.builder_make(context.temp_allocator)
 strings.write_string(&b, cl.storage_path); strings.write_string(&b, ".config-")
 for v in digest { fmt.sbprintf(&b, "%02x", v) }
 return strings.to_string(b)
}

clear_config :: proc(cl: ^Client, erase: bool) {
 if erase { path := config_path(cl); if len(path)>0 { os.remove(path) } }
 json.destroy_value(cl.remote.document)
 delete(cl.remote.etag, cl.allocator)
 cl.remote = Remote_Config{generation=cl.remote.generation+1}
}

config_name :: proc(s: string, limit: int, variant := false) -> bool {
 if len(s)==0 || len(s)>limit { return false }
 for c, i in s {
  if i==0 && !(c>='a' && c<='z') { return false }
  if !(c>='a' && c<='z' || c>='0' && c<='9' || c=='_' || variant && c=='-') { return false }
 }
 return true
}
config_safe :: proc(v: json.Value, depth: int=0) -> bool {
 if depth>20 { return false }
 #partial switch x in v {
 case json.Object:
  for k, child in x { if k=="__proto__" || k=="constructor" || k=="prototype" || !config_safe(child, depth+1) { return false } }
 case json.Array:
  for child in x { if !config_safe(child, depth+1) { return false } }
 }
 return true
}
config_install :: proc(cl: ^Client, body: []u8) -> bool {
 if len(body)>450_000 { return false }
 parsed, err := json.parse(body, spec=.JSON, parse_integers=true, allocator=context.temp_allocator)
 if err!=nil { return false }
 obj, ok := parsed.(json.Object); if !ok { return false }
 values, vok := obj["values"].(json.Object)
 assignments, aok := obj["experiments"].(json.Array)
 etag, eok := obj["etag"].(json.String)
 if !vok || !aok || !eok || len(values)>50 || len(assignments)>10 || len(etag)!=66 || etag[0]!='"' || etag[65]!='"' { return false }
 for c in etag[1:65] { if !(c>='0' && c<='9' || c>='a' && c<='f') { return false } }
 for key, value in values {
  encoded, e := json.unparse(value, allocator=context.temp_allocator)
  if !config_name(key,64) || key=="constructor" || key=="prototype" || e!=nil || len(encoded)>8192 || !config_safe(value) { return false }
 }
 seen := make(map[string]bool, context.temp_allocator)
 for a in assignments {
  item, iok := a.(json.Object); if !iok { return false }
  key, kok := item["key"].(json.String); variant, rok := item["variant"].(json.String)
  if !kok || !rok || !config_name(key,64) || !config_name(variant,40,true) || seen[key] { return false }
  seen[key]=true
 }
 // Validate in scratch memory first: malformed nested JSON must never retain
 // partial parser allocations in the long-lived client allocator.
 owned, owned_err := json.parse(body, spec=.JSON, parse_integers=true, allocator=cl.allocator)
 if owned_err!=nil { return false }
 json.destroy_value(cl.remote.document); delete(cl.remote.etag, cl.allocator)
 cl.remote.document=owned; cl.remote.etag=strings.clone(etag, cl.allocator)
 return true
}
config_escape :: proc(s: string) -> string {
 b:=strings.builder_make(context.temp_allocator)
 for c in transmute([]u8)s {
  if c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='-' || c=='_' || c=='.' || c=='~' { strings.write_byte(&b,c) } else { fmt.sbprintf(&b,"%%%02X",c) }
 }
 return strings.to_string(b)
}

load_config_cache :: proc(cl: ^Client) {
 if !core_is_active(&cl.core) { return }
 if !cl.remote.loaded {
  cl.remote.loaded=true
  path:=config_path(cl)
  if len(path)>0 {
   info, stat_err := os.stat(path, context.temp_allocator)
   if stat_err==nil && info.size<=450_000 {
    body, err:=os.read_entire_file(path,context.temp_allocator)
    if err==nil { config_install(cl,body) }
   }
  }
 }
}

// Nonblocking. tick pumps the request; fresh=false means cached/default fallback.
fetch_config :: proc(cl: ^Client) {
 if cl==nil || !core_is_active(&cl.core) || cl.remote.pending { return }
 context.allocator=cl.allocator
 load_config_cache(cl)
 path:=fmt.tprintf("/ingest/config?deviceId=%s&platform=%s&gameVersion=%s",config_escape(cl.device_id),config_escape(cl.platform),config_escape(cl.game_version))
 headers:=make([dynamic]string,context.temp_allocator)
 if len(cl.remote.etag)>0 { append(&headers,fmt.tprintf("If-None-Match: %s",cl.remote.etag)) }
 transfer:=start_request(cl,path,"",.API_Key,headers[:])
 if transfer==nil { if cl.cb.on_config_ready!=nil { cl.cb.on_config_ready(cl.cb.user,false) }; return }
 transfer.is_side=true; transfer.side=.Config; transfer.config_generation=cl.remote.generation
 append(&cl.side,transfer); cl.remote.pending=true
}
config_response :: proc(cl: ^Client, t: ^Transfer, status: int) {
 if t.config_generation!=cl.remote.generation || !core_is_active(&cl.core) { return }
 cl.remote.pending=false
 fresh:=status==304 && len(cl.remote.etag)>0
 if status==200 && config_install(cl,t.body_buf[:]) {
  fresh=true
  path:=config_path(cl)
  if len(path)>0 {
   tmp:=strings.concatenate({path,".tmp"},context.temp_allocator)
   if os.write_entire_file(tmp,t.body_buf[:])==nil { if os.rename(tmp,path)!=nil { os.remove(tmp) } }
  }
 }
 if status==401 || status==403 {
  parsed, ok:=parse_body(t.body_buf[:]); defer if ok { json.destroy_value(parsed) }
  obj,is_obj:=parsed.(json.Object); sig:Signals
  core_apply_refusal(&cl.core,status,error_code_of(obj,is_obj),&sig); dispatch(cl,sig)
 }
 if cl.cb.on_config_ready!=nil { cl.cb.on_config_ready(cl.cb.user,fresh) }
}
config_value :: proc(cl:^Client,key:string)->json.Value {
 if cl==nil || !core_is_active(&cl.core) { return nil }
 doc,ok:=cl.remote.document.(json.Object); if !ok { return nil }
 values,_:=doc["values"].(json.Object); return values[key]
}
// Strings are borrowed until the next successful config fetch, reset or shutdown.
get_config_string :: proc(cl:^Client,key:string,fallback:string="")->string { v,ok:=config_value(cl,key).(json.String); return ok ? string(v) : fallback }
get_config_bool :: proc(cl:^Client,key:string,fallback:bool=false)->bool { v,ok:=config_value(cl,key).(json.Boolean); return ok ? bool(v) : fallback }
get_config_number :: proc(cl:^Client,key:string,fallback:f64=0)->f64 {
 #partial switch v in config_value(cl,key) { case json.Integer: return f64(v); case json.Float: return f64(v) }; return fallback
}
// JSON text is copied into allocator; caller owns and deletes the returned string.
get_config_json :: proc(cl:^Client,key:string,fallback:string="null",allocator:=context.allocator)->string {
 v:=config_value(cl,key); if v==nil { return strings.clone(fallback,allocator) }
 result,err:=json.unparse(v,allocator=allocator); if err!=nil { return strings.clone(fallback,allocator) }; return result
}
with_config_exposures :: proc(cl:^Client,body:string)->string {
 body := len(body)==0 ? "{}" : body
 if cl.remote.document==nil && !strings.contains(body,"rs_exp_") { return body }
 parsed,err:=json.parse(transmute([]u8)body,spec=.JSON,parse_integers=true,allocator=context.temp_allocator)
 if err!=nil { return body }
 obj,ok:=parsed.(json.Object); if !ok { return body }
 // Reserved labels can only come from the current accepted config response.
 for key in obj { if strings.has_prefix(key,"rs_exp_") { delete_key(&obj,key) } }
 doc,has:=cl.remote.document.(json.Object)
 if has {
  assignments,_:=doc["experiments"].(json.Array)
  for a in assignments { item,_:=a.(json.Object); key,_:=item["key"].(json.String); obj[strings.concatenate({"rs_exp_",key},context.temp_allocator)]=item["variant"] }
 }
 result,e:=json.unparse(json.Value(obj),allocator=context.temp_allocator); return e==nil ? result : body
}
