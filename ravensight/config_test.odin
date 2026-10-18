package ravensight
import "core:testing"
import "core:strings"
import "core:fmt"
import "core:os"

CONFIG_FIXTURE :: `{"values":{"difficulty":2,"enabled":true,"label":"easy","nested":{"a":[1,2]}},"experiments":[{"key":"tutorial","variant":"short"}],"etag":"\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""}`

@(test)
test_config_fetch_etag_and_event_snapshot :: proc(t:^testing.T) {
 f:Fake; fake_init(&f); defer fake_destroy(&f)
 cl:=fake_client(t,&f,Config{device_id="player &1"}); defer close_client(cl)
 boot_client(t,&f,cl)
 track(cl,"before")
 fetch_config(cl)
 idx:=open_request(&f)
 testing.expect(t,strings.contains(f.requests[idx].path,"deviceId=player%20%261"))
 testing.expect(t,has_header(f.requests[idx],"X-API-Key: gt_live_test"))
 answer(&f,idx,200,CONFIG_FIXTURE)
 testing.expect_value(t,get_config_number(cl,"difficulty",9),f64(2))
 testing.expect_value(t,get_config_number(cl,"enabled",9),f64(9))
 testing.expect_value(t,get_config_bool(cl,"enabled"),true)
 testing.expect_value(t,get_config_string(cl,"label"),"easy")
 copy:=get_config_json(cl,"nested"); defer delete(copy)
 testing.expect(t,strings.contains(copy,"[1,2]"))
 testing.expect(t,!strings.contains(cl.core.queue[len(cl.core.queue)-1].data_json,"rs_exp_"))
 props:=make(map[string]string,context.temp_allocator)
 props["rs_exp_tutorial"]="forged"; props["rs_exp_fake"]="x"
 track(cl,"after",props)
 data:=cl.core.queue[len(cl.core.queue)-1].data_json
 testing.expect(t,strings.contains(data,`"rs_exp_tutorial":"short"`))
 testing.expect(t,!strings.contains(data,"rs_exp_fake"))
 fetch_config(cl); idx=open_request(&f)
 testing.expect(t,has_header(f.requests[idx],`If-None-Match: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`))
 answer(&f,idx,304)
 testing.expect_value(t,get_config_string(cl,"label"),"easy")
 fetch_config(cl); idx=open_request(&f); answer(&f,idx,200,`{"values":{}}`)
 testing.expect_value(t,get_config_string(cl,"label"),"easy")
}

@(test)
test_config_cache_scope_offline_reset_consent :: proc(t:^testing.T) {
 f:Fake; fake_init(&f); defer fake_destroy(&f)
 cfg:=Config{device_id="fixed",platform="odin",game_version="2"}
 cl:=fake_client(t,&f,cfg)
 fetch_config(cl); answer(&f,open_request(&f),200,CONFIG_FIXTURE)
 path:=strings.clone(config_path(cl),context.temp_allocator)
 testing.expect(t,os.exists(path)); close_client(cl)
 cl=fake_client(t,&f,cfg)
 testing.expect_value(t,get_config_string(cl,"label"),"easy")
 fetch_config(cl); answer(&f,open_request(&f),0)
 testing.expect_value(t,get_config_string(cl,"label"),"easy")
 fetch_config(cl); old:=open_request(&f)
 reset_device_id(cl); answer(&f,old,200,CONFIG_FIXTURE)
 testing.expect_value(t,get_config_string(cl,"label","default"),"default")
 testing.expect(t,!os.exists(path)); close_client(cl)
 cl=fake_client(t,&f,Config{consent=.Opt_In})
 before:=len(f.requests); fetch_config(cl)
 testing.expect_value(t,len(f.requests),before)
 close_client(cl)
}

@(test)
test_config_rejects_bounds_and_playtest_disk :: proc(t:^testing.T) {
 f:Fake; fake_init(&f); defer fake_destroy(&f)
 cl:=fake_client(t,&f,Config{playtest_token="token",playtest_run_id="run"}); defer close_client(cl)
 testing.expect_value(t,config_path(cl),"")
 testing.expect(t,config_install(cl,transmute([]u8)string(CONFIG_FIXTURE)))
 bad_values := []string{
  config_test_replace(`"difficulty":2`,`"__proto__":2`),
  config_test_replace(`"difficulty":2`,`"difficulty":{"constructor":2}`),
  config_test_replace(`"difficulty":2`,fmt.tprintf(`"difficulty":"%s"`,strings.repeat("x",8193,context.temp_allocator))),
  config_test_replace(`"variant":"short"`,`"variant":"invalid space"`),
 }
 for bad in bad_values { testing.expect(t,!config_install(cl,transmute([]u8)bad)) }
 fetch_config(cl); old:=open_request(&f)
 set_enabled(cl,false); set_enabled(cl,true)
 answer(&f,old,200,CONFIG_FIXTURE)
 testing.expect_value(t,get_config_string(cl,"label","fallback"),"fallback")
}

config_test_replace :: proc(old,new:string)->string { result,_:=strings.replace_all(CONFIG_FIXTURE,old,new,context.temp_allocator); return result }

@(test)
test_config_limits_scope_and_callback :: proc(t:^testing.T) {
 f:Fake; fake_init(&f); defer fake_destroy(&f)
 count:=0
 callbacks:=Callbacks{user=&count,on_config_ready=proc(user:rawptr,fresh:bool){ if fresh { (^int)(user)^+=1 } }}
 cl:=fake_client(t,&f,Config{device_id="fixed",callbacks=callbacks})
 fetch_config(cl); answer(&f,open_request(&f),200,CONFIG_FIXTURE)
 testing.expect_value(t,count,1)
 fetch_config(cl); answer(&f,open_request(&f),304)
 testing.expect_value(t,count,2)
 original:=strings.clone(config_path(cl),context.temp_allocator)
 close_client(cl)
 configs := [4]Config{
  {device_id="other"}, {device_id="fixed",game_version="new"},
  {device_id="fixed",ingest_key="gt_pub_other"}, {device_id="fixed",api_url="https://other.example/api/v1"},
 }
 for cfg in configs {
  isolated:=fake_client(t,&f,cfg)
  testing.expect(t,config_path(isolated)!=original)
  testing.expect_value(t,get_config_string(isolated,"label","none"),"none")
  close_client(isolated)
 }
 cl=fake_client(t,&f,Config{device_id="fixed"}); defer close_client(cl)
 testing.expect_value(t,get_config_string(cl,"label"),"easy")
 keys:=strings.builder_make(context.temp_allocator)
 for i in 0..<51 { if i>0 { strings.write_byte(&keys,',') }; fmt.sbprintf(&keys,`"key%d":1`,i) }
 bad,_:=strings.replace_all(CONFIG_FIXTURE,`"difficulty":2`,strings.to_string(keys),context.temp_allocator)
 testing.expect(t,!config_install(cl,transmute([]u8)bad))
 deep:=fmt.tprintf(`"difficulty":%s0%s`,strings.repeat("[",21,context.temp_allocator),strings.repeat("]",21,context.temp_allocator))
 bad=config_test_replace(`"difficulty":2`,deep)
 testing.expect(t,!config_install(cl,transmute([]u8)bad))
 repeated:=strings.builder_make(context.temp_allocator)
 for i in 0..<11 { if i>0 { strings.write_byte(&repeated,',') }; fmt.sbprintf(&repeated,`{"key":"test%d","variant":"control"}`,i) }
 bad=config_test_replace(`{"key":"tutorial","variant":"short"}`,strings.to_string(repeated))
 testing.expect(t,!config_install(cl,transmute([]u8)bad))
}
