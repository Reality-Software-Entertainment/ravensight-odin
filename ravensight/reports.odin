package ravensight

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

Report_Input :: struct {
 client_id, message: string,
 png: []u8,
 consent: bool,
 captured_at: i64,
 category: string,
}
Report_Stage :: enum { Begin, Status, Grant, Upload, Finalize }
// Keep this object alive until its callback; destroy_report refuses pending work.
Player_Report :: struct {
 payload, png, id, token, device: string,
 client: ^Client,
 pending, uploaded: bool,
 user: rawptr,
 callback: proc(user: rawptr, status, reason: string),
}
report_name :: proc(value: string, low, high: int) -> bool {
 if len(value)<low || len(value)>high { return false }
 for c in value { if !(c>='a'&&c<='z'||c>='A'&&c<='Z'||c>='0'&&c<='9'||c=='_'||c=='-') { return false } }
 return true
}
report_png :: proc(png: []u8) -> bool {
 if len(png)<33 || len(png)>1_000_000 || string(png[:8])!="\x89PNG\r\n\x1a\n" || string(png[12:16])!="IHDR" {return false}
 size := proc(bytes: []u8) -> u32 {return u32(bytes[0])<<24 | u32(bytes[1])<<16 | u32(bytes[2])<<8 | u32(bytes[3])}
 w,h:=size(png[16:20]),size(png[20:24])
 return size(png[8:12])==13 && w>0 && h>0 && w<=1600 && h<=1600
}
create_report :: proc(input: Report_Input) -> (^Player_Report, string) {
 if !input.consent {return nil,"report_consent_required"}
 if !report_name(input.client_id,8,80) || len(strings.trim_space(input.message))==0 || len(input.message)>500 || !report_png(input.png) {return nil,"invalid_report"}
 now:=time.to_unix_nanoseconds(time.now()) / 1_000_000_000; captured:=input.captured_at; if captured==0 {captured=now}
 if captured<now-86400 || captured>now+60 {return nil,"invalid_capture_time"}
 category:=input.category; if category=="" {category="other"}
 found:=false;for item in FEEDBACK_CATEGORIES {if item==category {found=true}}
 if !found {return nil,"invalid_category"}
 hash:sha2.Context_256;sha2.init_256(&hash);sha2.update(&hash,input.png);digest:[32]u8;sha2.final(&hash,digest[:])
 hex:=strings.builder_make(context.temp_allocator);for b in digest {fmt.sbprintf(&hex,"%02x",b)}
 b:=strings.builder_make(context.temp_allocator)
 strings.write_string(&b,`{"clientId":`);write_json_string(&b,input.client_id)
 strings.write_string(&b,`,"message":`);write_json_string(&b,input.message)
 strings.write_string(&b,`,"category":`);write_json_string(&b,category)
 fmt.sbprintf(&b,`,"source":"player","image":true,"capturedAt":%d,"bytes":%d,"sha256":`,captured,len(input.png));write_json_string(&b,strings.to_string(hex));strings.write_byte(&b,'}')
 report:=new(Player_Report);report.payload=strings.clone(strings.to_string(b));report.png=strings.clone(string(input.png));return report,""
}
destroy_report :: proc(report: ^Player_Report) -> bool {
 if report==nil || report.pending {return false}
 delete(report.payload);delete(report.png);delete(report.id);delete(report.token);delete(report.device);free(report);return true
}
report_active :: proc(cl:^Client,r:^Player_Report)->bool {
 return cl!=nil && core_is_active(&cl.core) && len(cl.core.session_token)>0 && (r.client==nil || r.client==cl && r.token==cl.core.session_token && r.device==cl.device_id)
}
report_done :: proc(r:^Player_Report,status,reason:string) {
 r.pending=false
 if r.callback!=nil {r.callback(r.user,status,reason)}
}
report_send :: proc(cl:^Client,r:^Player_Report,stage:Report_Stage,path,body:string,headers:[]string=nil,upload:=false)->bool {
 if !report_active(cl,r) {report_done(r,"","report_session_unavailable");return false}
 t:=start_request(cl,path,body,upload ? .None : .Session_Token,headers,upload)
 if t==nil {report_done(r,"","report_request_failed");return false}
 t.is_side=true;t.side=.Report;t.report=r;t.report_stage=stage;append(&cl.side,t);return true
}
submit_report :: proc(cl:^Client,r:^Player_Report,callback:proc(user:rawptr,status,reason:string),user:rawptr=nil)->bool {
 if r==nil || r.pending || callback==nil || !report_active(cl,r) {return false}
 if r.client==nil {r.client=cl;r.token=strings.clone(cl.core.session_token);r.device=strings.clone(cl.device_id)}
 r.pending=true;r.callback=callback;r.user=user
 if r.id!="" {return report_send(cl,r,.Status,fmt.tprintf("/reports/%s",r.id),"")}
 return report_send(cl,r,.Begin,"/reports",r.payload)
}
report_string :: proc(obj:json.Object,key:string)->string {v,ok:=obj[key];if !ok{return ""};s,is:=v.(json.String);return is ? string(s) : ""}
report_response :: proc(cl:^Client,t:^Transfer,status:int) {
 r:=t.report
 if !report_active(cl,r) {report_done(r,"","report_session_unavailable");return}
 if status<200 || status>=300 {report_done(r,"","report_request_failed");return}
 if t.report_stage==.Upload {r.uploaded=true;report_send(cl,r,.Finalize,fmt.tprintf("/reports/%s/finalize",r.id),"{}");return}
 parsed,ok:=parse_body(t.body_buf[:]);defer if ok {json.destroy_value(parsed)}
 obj,is:=parsed.(json.Object);if !is {report_done(r,"","invalid_response");return}
 if t.report_stage==.Grant {
  url:=report_string(obj,"url")
  // Dedicated HTTPS S3 grants only; never send session/ingest/playtest credentials.
  if !strings.has_prefix(url,"https://") {report_done(r,"","invalid_upload");return}
  host:=strings.trim_suffix(url[8:],"/")
  if !strings.has_suffix(host,".amazonaws.com") || !strings.contains(host,".s3") {report_done(r,"","invalid_upload");return}
  for c in host {if !(c>='a'&&c<='z'||c>='A'&&c<='Z'||c>='0'&&c<='9'||c=='-'||c=='.'){report_done(r,"","invalid_upload");return}}
  value,has:=obj["fields"];fields,object:=value.(json.Object)
  if !has || !object || len(fields)==0 || len(fields)>30 {report_done(r,"","invalid_upload");return}
  boundary:=fmt.tprintf("ravensight_%s",r.id)
  if strings.contains(r.png,boundary) {report_done(r,"","invalid_upload");return}
  body:=strings.builder_make(context.temp_allocator);total:=0
  for key,raw in fields {
   text,valid:=raw.(json.String)
   if !valid || !report_name(key,1,100) || key=="file" || len(text)>16384 || strings.contains(string(text),"\r") || strings.contains(string(text),"\n") {report_done(r,"","invalid_upload");return}
   total+=len(key)+len(text);if total>32768 {report_done(r,"","invalid_upload");return}
   fmt.sbprintf(&body,"--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n",boundary,key,text)
  }
  fmt.sbprintf(&body,"--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"screenshot.png\"\r\nContent-Type: application/octet-stream\r\n\r\n",boundary)
  strings.write_string(&body,r.png);fmt.sbprintf(&body,"\r\n--%s--\r\n",boundary)
  headers:=[1]string{fmt.tprintf("Content-Type: multipart/form-data; boundary=%s",boundary)}
  report_send(cl,r,.Upload,url,strings.to_string(body),headers[:],true);return
 }
 id,state:=report_string(obj,"id"),report_string(obj,"status")
 if len(id)!=24 || !report_name(id,24,24) || r.id!="" && r.id!=id {report_done(r,"","invalid_response");return}
 for c in id {if !(c>='a'&&c<='f'||c>='0'&&c<='9'){report_done(r,"","invalid_response");return}}
 if r.id=="" {r.id=strings.clone(id)}
 if state=="complete" || state=="processing" || state=="canceled" {report_done(r,state,"");return}
 if state!="pending" || t.report_stage==.Finalize {report_done(r,"","invalid_response");return}
 if r.uploaded {report_send(cl,r,.Finalize,fmt.tprintf("/reports/%s/finalize",r.id),"{}");return}
 report_send(cl,r,.Grant,fmt.tprintf("/reports/%s/upload",r.id),"{}")
}
