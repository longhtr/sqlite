#define SQLITE_CORE 1
#include "sqlite3.h"
#include "sqlite3ext.h"
#include <stdarg.h>
#include <stdio.h>

extern int zig_sqlite3_config_no_args(int);
extern int zig_sqlite3_config_memstatus(int);
extern int zig_sqlite3_config_log(void(*)(void*,int,const char*),void*);
extern void zig_sqlite3_log_message(int,const char*);
extern int zig_sqlite3_db_config_main_name(sqlite3*,const char*);
extern int zig_sqlite3_db_config_lookaside(sqlite3*,void*,int,int);
extern int zig_sqlite3_db_config_flag(sqlite3*,int,int,int*);
extern int zig_sqlite3_vtab_config(sqlite3*,int,int);
extern int zig_sqlite3_test_control_no_args(int);
extern int zig_sqlite3_test_control_int(int,int);
static const sqlite3_api_routines extension_api={
  .aggregate_context=sqlite3_aggregate_context,.aggregate_count=sqlite3_aggregate_count,
  .bind_blob=sqlite3_bind_blob,.bind_double=sqlite3_bind_double,.bind_int=sqlite3_bind_int,
  .bind_int64=sqlite3_bind_int64,.bind_null=sqlite3_bind_null,.bind_parameter_count=sqlite3_bind_parameter_count,
  .bind_parameter_index=sqlite3_bind_parameter_index,.bind_parameter_name=sqlite3_bind_parameter_name,
  .bind_text=sqlite3_bind_text,.bind_text16=sqlite3_bind_text16,.bind_value=sqlite3_bind_value,
  .busy_handler=sqlite3_busy_handler,.busy_timeout=sqlite3_busy_timeout,.changes=sqlite3_changes,
  .close=sqlite3_close,.column_blob=sqlite3_column_blob,.column_bytes=sqlite3_column_bytes,
  .column_bytes16=sqlite3_column_bytes16,.column_count=sqlite3_column_count,.column_double=sqlite3_column_double,
  .column_int=sqlite3_column_int,.column_int64=sqlite3_column_int64,.column_name=sqlite3_column_name,
  .column_name16=sqlite3_column_name16,.column_text=sqlite3_column_text,.column_text16=sqlite3_column_text16,
  .column_type=sqlite3_column_type,.column_value=sqlite3_column_value,.commit_hook=sqlite3_commit_hook,
  .complete=sqlite3_complete,.complete16=sqlite3_complete16,.create_function=sqlite3_create_function,
  .create_function16=sqlite3_create_function16,.create_module=sqlite3_create_module,.data_count=sqlite3_data_count,.db_handle=sqlite3_db_handle,
  .declare_vtab=sqlite3_declare_vtab,
  .errcode=sqlite3_errcode,.errmsg=sqlite3_errmsg,.errmsg16=sqlite3_errmsg16,.exec=sqlite3_exec,
  .expired=sqlite3_expired,.finalize=sqlite3_finalize,.free=sqlite3_free,.free_table=sqlite3_free_table,
  .get_autocommit=sqlite3_get_autocommit,.get_auxdata=sqlite3_get_auxdata,.get_table=sqlite3_get_table,
  .interruptx=sqlite3_interrupt,.last_insert_rowid=sqlite3_last_insert_rowid,.libversion=sqlite3_libversion,
  .libversion_number=sqlite3_libversion_number,.malloc=sqlite3_malloc,.mprintf=sqlite3_mprintf,
  .open=sqlite3_open,.open16=sqlite3_open16,.prepare=sqlite3_prepare,.prepare16=sqlite3_prepare16,
  .progress_handler=sqlite3_progress_handler,.realloc=sqlite3_realloc,.reset=sqlite3_reset,
  .result_blob=sqlite3_result_blob,.result_double=sqlite3_result_double,.result_error=sqlite3_result_error,
  .result_error16=sqlite3_result_error16,.result_int=sqlite3_result_int,.result_int64=sqlite3_result_int64,
  .result_null=sqlite3_result_null,.result_text=sqlite3_result_text,.result_text16=sqlite3_result_text16,
  .result_text16be=sqlite3_result_text16be,.result_text16le=sqlite3_result_text16le,
  .result_value=sqlite3_result_value,.rollback_hook=sqlite3_rollback_hook,.set_authorizer=sqlite3_set_authorizer,
  .set_auxdata=sqlite3_set_auxdata,.xsnprintf=sqlite3_snprintf,.step=sqlite3_step,
  .table_column_metadata=sqlite3_table_column_metadata,.total_changes=sqlite3_total_changes,
  .trace=sqlite3_trace,.transfer_bindings=sqlite3_transfer_bindings,.update_hook=sqlite3_update_hook,
  .user_data=sqlite3_user_data,.value_blob=sqlite3_value_blob,.value_bytes=sqlite3_value_bytes,
  .value_bytes16=sqlite3_value_bytes16,.value_double=sqlite3_value_double,.value_int=sqlite3_value_int,
  .value_int64=sqlite3_value_int64,.value_numeric_type=sqlite3_value_numeric_type,
  .value_text=sqlite3_value_text,.value_text16=sqlite3_value_text16,.value_text16be=sqlite3_value_text16be,
  .value_text16le=sqlite3_value_text16le,.value_type=sqlite3_value_type,.vmprintf=sqlite3_vmprintf,
  .overload_function=sqlite3_overload_function,.prepare_v2=sqlite3_prepare_v2,.prepare16_v2=sqlite3_prepare16_v2,
  .clear_bindings=sqlite3_clear_bindings,.create_function_v2=sqlite3_create_function_v2,.create_module_v2=sqlite3_create_module_v2,
  .extended_result_codes=sqlite3_extended_result_codes,.result_zeroblob=sqlite3_result_zeroblob,
  .value_dup=sqlite3_value_dup,.value_free=sqlite3_value_free,.result_zeroblob64=sqlite3_result_zeroblob64,
  .bind_zeroblob64=sqlite3_bind_zeroblob64,.changes64=sqlite3_changes64,.total_changes64=sqlite3_total_changes64,
  .prepare_v3=sqlite3_prepare_v3,.serialize=sqlite3_serialize,.deserialize=sqlite3_deserialize,
  .expanded_sql=sqlite3_expanded_sql,.str_new=sqlite3_str_new,.str_finish=sqlite3_str_finish,
  .str_append=sqlite3_str_append,.str_appendall=sqlite3_str_appendall,.str_appendchar=sqlite3_str_appendchar,
  .str_reset=sqlite3_str_reset,.str_errcode=sqlite3_str_errcode,.str_length=sqlite3_str_length,
  .str_value=sqlite3_str_value,.value_frombind=sqlite3_value_frombind,.value_subtype=sqlite3_value_subtype,
  .result_subtype=sqlite3_result_subtype,.error_offset=sqlite3_error_offset,.drop_modules=sqlite3_drop_modules,
  .vtab_config=sqlite3_vtab_config,.vtab_on_conflict=sqlite3_vtab_on_conflict,.vtab_nochange=sqlite3_vtab_nochange,
  .vtab_collation=sqlite3_vtab_collation,.vtab_rhs_value=sqlite3_vtab_rhs_value,.vtab_distinct=sqlite3_vtab_distinct,
  .vtab_in=sqlite3_vtab_in,.vtab_in_first=sqlite3_vtab_in_first,.vtab_in_next=sqlite3_vtab_in_next,
  .vfs_find=sqlite3_vfs_find,.vfs_register=sqlite3_vfs_register,.vfs_unregister=sqlite3_vfs_unregister
};

extern void zig_sqlite3_set_extension_api(const sqlite3_api_routines*);
#if defined(__GNUC__)
__attribute__((constructor)) static void configure_extension_api(void){zig_sqlite3_set_extension_api(&extension_api);}
#endif

SQLITE_API int sqlite3_config(int operation,...){
  va_list arguments;
  int result=SQLITE_OK;
  va_start(arguments,operation);
  switch(operation){
    case SQLITE_CONFIG_SINGLETHREAD:
    case SQLITE_CONFIG_MULTITHREAD:
    case SQLITE_CONFIG_SERIALIZED:
      result=zig_sqlite3_config_no_args(operation);
      break;
    case SQLITE_CONFIG_MEMSTATUS:
      result=zig_sqlite3_config_memstatus(va_arg(arguments,int));
      break;
    case SQLITE_CONFIG_LOG:{
      void (*callback)(void*,int,const char*)=va_arg(arguments,void(*)(void*,int,const char*));
      void *context=va_arg(arguments,void*);
      result=zig_sqlite3_config_log(callback,context);
      break;
    }
    default:
      result=zig_sqlite3_config_no_args(operation);
      break;
  }
  va_end(arguments);
  return result;
}

SQLITE_API int sqlite3_vtab_config(sqlite3 *db,int operation,...){
  va_list arguments;
  int value=0;
  if(operation==SQLITE_VTAB_CONSTRAINT_SUPPORT){
    va_start(arguments,operation);
    value=va_arg(arguments,int);
    va_end(arguments);
  }
  return zig_sqlite3_vtab_config(db,operation,value);
}

SQLITE_API int sqlite3_db_config(sqlite3 *db,int operation,...){
  va_list arguments;
  int result;
  va_start(arguments,operation);
  if(operation==SQLITE_DBCONFIG_MAINDBNAME){
    result=zig_sqlite3_db_config_main_name(db,va_arg(arguments,const char*));
  }else if(operation==SQLITE_DBCONFIG_LOOKASIDE){
    void *buffer=va_arg(arguments,void*);
    int slot_size=va_arg(arguments,int);
    int slot_count=va_arg(arguments,int);
    result=zig_sqlite3_db_config_lookaside(db,buffer,slot_size,slot_count);
  }else if(operation>=SQLITE_DBCONFIG_ENABLE_FKEY && operation<=SQLITE_DBCONFIG_MAX){
    int enabled=va_arg(arguments,int);
    int *output=va_arg(arguments,int*);
    result=zig_sqlite3_db_config_flag(db,operation,enabled,output);
  }else{
    result=SQLITE_ERROR;
  }
  va_end(arguments);
  return result;
}

SQLITE_API int sqlite3_test_control(int operation,...){
  va_list arguments;
  int value;
  switch(operation){
    case SQLITE_TESTCTRL_ALWAYS:
    case SQLITE_TESTCTRL_ASSERT:
      va_start(arguments,operation);
      value=va_arg(arguments,int);
      va_end(arguments);
      return zig_sqlite3_test_control_int(operation,value);
    default:
      return zig_sqlite3_test_control_no_args(operation);
  }
}

SQLITE_API void sqlite3_log(int code,const char *format,...){
  char *message;
  va_list arguments;
  if(!format) return;
  va_start(arguments,format);
  message=sqlite3_vmprintf(format,arguments);
  va_end(arguments);
  if(message){zig_sqlite3_log_message(code,message);sqlite3_free(message);}
}

SQLITE_API char *sqlite3_vmprintf(const char *format, va_list arguments){
  va_list copy;
  int length;
  char *output;
  if(!format) return 0;
  va_copy(copy,arguments);
  length=vsnprintf(0,0,format,copy);
  va_end(copy);
  if(length<0) return 0;
  output=(char*)sqlite3_malloc64((sqlite3_uint64)length+1);
  if(!output) return 0;
  va_copy(copy,arguments);
  if(vsnprintf(output,(size_t)length+1,format,copy)<0){va_end(copy);sqlite3_free(output);return 0;}
  va_end(copy);
  return output;
}

SQLITE_API char *sqlite3_mprintf(const char *format,...){
  char *output;
  va_list arguments;
  va_start(arguments,format);
  output=sqlite3_vmprintf(format,arguments);
  va_end(arguments);
  return output;
}

SQLITE_API char *sqlite3_vsnprintf(int size,char *output,const char *format,va_list arguments){
  if(!output || size<=0) return output;
  if(!format){output[0]=0;return output;}
  (void)vsnprintf(output,(size_t)size,format,arguments);
  output[size-1]=0;
  return output;
}

SQLITE_API char *sqlite3_snprintf(int size,char *output,const char *format,...){
  va_list arguments;
  va_start(arguments,format);
  (void)sqlite3_vsnprintf(size,output,format,arguments);
  va_end(arguments);
  return output;
}

SQLITE_API void sqlite3_str_vappendf(sqlite3_str *builder,const char *format,va_list arguments){
  char *text=sqlite3_vmprintf(format,arguments);
  if(text){sqlite3_str_appendall(builder,text);sqlite3_free(text);}
}

SQLITE_API void sqlite3_str_appendf(sqlite3_str *builder,const char *format,...){
  va_list arguments;
  va_start(arguments,format);
  sqlite3_str_vappendf(builder,format,arguments);
  va_end(arguments);
}
