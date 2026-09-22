#define _GNU_SOURCE
#include <moonbit.h>
#include <mariadb/mysql.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// Foreign threads own only malloc memory and Connector/C objects. MoonBit
// objects are copied before submission; completion is observed through a pipe.
static void *alloc(size_t n) { void *p = calloc(1, n ? n : 1); if (!p) abort(); return p; }
static char *copy_bytes(const uint8_t *s) {
  size_t n = Moonbit_array_length(s); char *p = alloc(n + 1); memcpy(p, s, n); return p;
}
static moonbit_bytes_t bytes(const void *s, size_t n) {
  moonbit_bytes_t p = moonbit_make_bytes((int32_t)n, 0); if (n) memcpy(p, s, n); return p;
}
static moonbit_bytes_t text(const char *s) { return bytes(s, strlen(s)); }

static pthread_once_t library_once = PTHREAD_ONCE_INIT;
static int library_ready;
static void initialize_library(void) { library_ready = mysql_library_init(0, NULL, NULL) == 0; }

typedef struct { int kind; char *data; unsigned long len; double number; int64_t integer; uint64_t unsigned_integer; } Param;
typedef struct { char *sql; int count; Param *params; } Statement;
typedef struct { char *data; unsigned long len; int null; } Cell;
typedef struct {
  MYSQL *mysql; char *host, *user, *password, *database, *ssl_ca, *plugin_dir; unsigned port;
  unsigned timeout; int max_rows; size_t max_bytes;
  pthread_t thread; pthread_mutex_t mutex; pthread_cond_t cond;
  int pipefd[2], pending, stopping, transaction, error;
  Statement *statements; int statement_count;
  char **names; int *kinds; Cell *cells; int cols, rows; size_t capacity, result_size;
  uint64_t affected, insert_id;
} Database;

static void clear_result(Database *d) {
  for (int i=0; i<d->cols; i++) free(d->names[i]);
  for (size_t i=0; i<(size_t)d->rows*d->cols; i++) free(d->cells[i].data);
  free(d->names); free(d->kinds); free(d->cells);
  d->names=NULL; d->kinds=NULL; d->cells=NULL;
  d->cols=d->rows=0; d->capacity=d->result_size=0; d->affected=d->insert_id=0;
}
static void clear_statements(Database *d) {
  for (int i=0; i<d->statement_count; i++) {
    Statement *s=&d->statements[i];
    free(s->sql); for (int j=0; j<s->count; j++) free(s->params[j].data);
    free(s->params);
  }
  free(d->statements); d->statements=NULL; d->statement_count=0;
}
static int connect_db(Database *d) {
  if (d->mysql) return 1;
  MYSQL *m=mysql_init(NULL); if (!m) return 0;
  unsigned timeout=d->timeout;
  mysql_options(m, MYSQL_OPT_CONNECT_TIMEOUT, &timeout);
  mysql_options(m, MYSQL_OPT_READ_TIMEOUT, &timeout);
  mysql_options(m, MYSQL_OPT_WRITE_TIMEOUT, &timeout);
  mysql_options(m, MYSQL_SET_CHARSET_NAME, "utf8mb4");
  // Explicit TLS verification when a CA is configured; Connector/C also handles
  // MySQL 8 caching_sha2_password. Never enable multi-statements or LOCAL INFILE.
  const char *ca=d->ssl_ca;
  if (ca && *ca) { my_bool yes=1; mysql_options(m, MYSQL_OPT_SSL_CA, ca); mysql_options(m, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &yes); mysql_options(m, MYSQL_OPT_SSL_ENFORCE, &yes); }
  unsigned local=0; mysql_options(m, MYSQL_OPT_LOCAL_INFILE, &local);
  const char *plugin=d->plugin_dir; if (*plugin) mysql_options(m, MYSQL_PLUGIN_DIR, plugin);
  if (!mysql_real_connect(m,d->host,d->user,d->password,d->database,d->port,NULL,CLIENT_FOUND_ROWS)) { d->error=mysql_errno(m); mysql_close(m); return 0; }
  if (mysql_query(m,"SET time_zone = '+00:00'")) { d->error=mysql_errno(m); mysql_close(m); return 0; }
  d->mysql=m; return 1;
}
static int execute_statement(Database *d, Statement *s) {
  MYSQL_STMT *stmt=mysql_stmt_init(d->mysql); if (!stmt) return 0;
  MYSQL_BIND *bind=alloc(sizeof(MYSQL_BIND)*s->count);
  MYSQL_RES *meta=NULL; MYSQL_BIND *out=NULL; unsigned long *lengths=NULL; my_bool *nulls=NULL;
  int ok=0;
  if (mysql_stmt_prepare(stmt,s->sql,strlen(s->sql))) goto done;
  if (mysql_stmt_param_count(stmt)!=(unsigned long)s->count) { d->error=-3; goto done; }
  for (int i=0;i<s->count;i++) {
    Param *p=&s->params[i];
    if (p->kind==0) bind[i].buffer_type=MYSQL_TYPE_NULL;
    else if(p->kind==1) { bind[i].buffer_type=MYSQL_TYPE_DOUBLE; bind[i].buffer=&p->number; }
    else if(p->kind==4) { bind[i].buffer_type=MYSQL_TYPE_LONGLONG; bind[i].buffer=&p->integer; }
    else if(p->kind==5) { bind[i].buffer_type=MYSQL_TYPE_LONGLONG; bind[i].buffer=&p->unsigned_integer; bind[i].is_unsigned=1; }
    else { bind[i].buffer_type=p->kind==3 ? MYSQL_TYPE_BLOB : MYSQL_TYPE_STRING; bind[i].buffer=p->data; bind[i].buffer_length=p->len; bind[i].length=&p->len; }
  }
  if (s->count && mysql_stmt_bind_param(stmt,bind)) goto done;
  if (mysql_stmt_execute(stmt)) goto done;
  clear_result(d);
  meta=mysql_stmt_result_metadata(stmt);
  if (!meta) { d->affected=mysql_stmt_affected_rows(stmt); d->insert_id=mysql_stmt_insert_id(stmt); ok=1; goto done; }
  d->cols=(int)mysql_num_fields(meta);
  d->names=alloc(sizeof(char*)*d->cols); d->kinds=alloc(sizeof(int)*d->cols);
  out=alloc(sizeof(MYSQL_BIND)*d->cols); lengths=alloc(sizeof(unsigned long)*d->cols); nulls=alloc(sizeof(my_bool)*d->cols);
  MYSQL_FIELD *fields=mysql_fetch_fields(meta);
  for (int i=0;i<d->cols;i++) {
    d->names[i]=strdup(fields[i].name);
    enum enum_field_types t=fields[i].type;
    if (t==MYSQL_TYPE_TINY || t==MYSQL_TYPE_SHORT || t==MYSQL_TYPE_LONG || t==MYSQL_TYPE_LONGLONG || t==MYSQL_TYPE_INT24 || t==MYSQL_TYPE_YEAR)
      d->kinds[i] = (fields[i].flags & UNSIGNED_FLAG) ? 2 : 1;
    else if (t==MYSQL_TYPE_FLOAT || t==MYSQL_TYPE_DOUBLE) d->kinds[i]=3;
    else if (t==MYSQL_TYPE_DECIMAL || t==MYSQL_TYPE_NEWDECIMAL) d->kinds[i]=4;
    else if (t==MYSQL_TYPE_BIT || ((t==MYSQL_TYPE_BLOB || t==MYSQL_TYPE_TINY_BLOB || t==MYSQL_TYPE_MEDIUM_BLOB || t==MYSQL_TYPE_LONG_BLOB || t==MYSQL_TYPE_STRING || t==MYSQL_TYPE_VARCHAR || t==MYSQL_TYPE_VAR_STRING) && fields[i].charsetnr==63)) d->kinds[i]=5;
    else d->kinds[i]=0;
    // Connector/C needs a real initial buffer to compute numeric-to-text
    // lengths. A NULL/zero buffer can report length zero for DOUBLE values.
    out[i].buffer_type=MYSQL_TYPE_STRING; out[i].buffer=alloc(64); out[i].buffer_length=64; out[i].length=&lengths[i]; out[i].is_null=&nulls[i];
  }
  if (mysql_stmt_bind_result(stmt,out)) goto done;
  // Fetch incrementally; do not buffer an unbounded result inside Connector/C.
  for (;;) {
    int status=mysql_stmt_fetch(stmt);
    if (status==MYSQL_NO_DATA) { ok=1; break; }
    if (status && status!=MYSQL_DATA_TRUNCATED) goto done;
    if (d->rows>=d->max_rows) { d->error=-2; goto done; }
    size_t need=(size_t)(d->rows+1)*d->cols;
    if (need>d->capacity) { size_t cap=need*2; Cell *next=realloc(d->cells,cap*sizeof(Cell)); if(!next) abort(); d->cells=next; memset(next+d->capacity,0,(cap-d->capacity)*sizeof(Cell)); d->capacity=cap; }
    int row=d->rows++;
    for(int i=0;i<d->cols;i++) {
      Cell *c=&d->cells[(size_t)row*d->cols+i]; c->null=nulls[i]; c->len=lengths[i];
      if (c->null) continue;
      d->result_size+=c->len;
      if (d->result_size>d->max_bytes) { d->error=-2; goto done; }
      c->data=alloc(c->len+1); MYSQL_BIND col={0};
      col.buffer_type=MYSQL_TYPE_STRING; col.buffer=c->data; col.buffer_length=c->len+1;
      if (mysql_stmt_fetch_column(stmt,&col,i,0)) goto done;
    }
  }
done:
  if (!ok && !d->error) d->error=mysql_stmt_errno(stmt) ? mysql_stmt_errno(stmt) : 1;
  if (meta) mysql_free_result(meta);
  free(bind); if(out) { for(int i=0;i<d->cols;i++) free(out[i].buffer); } free(out); free(lengths); free(nulls); mysql_stmt_close(stmt);
  return ok;
}
static void *worker(void *arg) {
  Database *d=arg; mysql_thread_init();
  pthread_mutex_lock(&d->mutex);
  for (;;) {
    while (!d->pending && !d->stopping) pthread_cond_wait(&d->cond,&d->mutex);
    if (d->stopping) break;
    pthread_mutex_unlock(&d->mutex);
    d->error=0;
    int ok=connect_db(d);
    if (ok && d->transaction && mysql_query(d->mysql,"START TRANSACTION")) { d->error=mysql_errno(d->mysql); ok=0; }
    for (int i=0;ok && i<d->statement_count;i++) ok=execute_statement(d,&d->statements[i]);
    if (d->transaction && d->mysql) {
      if (ok) { if(mysql_commit(d->mysql)) { d->error=mysql_errno(d->mysql); ok=0; mysql_rollback(d->mysql); } }
      else mysql_rollback(d->mysql);
    }
    if (!ok) {
      if (!d->error) d->error=1;
      // Never retry an uncertain write; next request may establish a fresh session.
      if (d->mysql) { mysql_close(d->mysql); d->mysql=NULL; }
    }
    pthread_mutex_lock(&d->mutex); d->pending=0; pthread_mutex_unlock(&d->mutex);
    uint8_t done=1; while (write(d->pipefd[1],&done,1)<0 && errno==EINTR) {}
    pthread_mutex_lock(&d->mutex);
  }
  pthread_mutex_unlock(&d->mutex);
  if(d->mysql) mysql_close(d->mysql);
  mysql_thread_end(); return NULL;
}
void *sk_mysql_new(const uint8_t *host,const uint8_t *user,const uint8_t *pass,const uint8_t *name,int32_t port,const uint8_t *ssl_ca,const uint8_t *plugin_dir,int32_t timeout,int32_t max_rows,int32_t max_bytes) {
  pthread_once(&library_once, initialize_library);
  if (!library_ready) return NULL;
  Database *d=alloc(sizeof(*d));
  int mutex_ready=0, cond_ready=0;
  d->pipefd[0]=d->pipefd[1]=-1;
  d->host=copy_bytes(host); d->user=copy_bytes(user); d->password=copy_bytes(pass); d->database=copy_bytes(name); d->port=port;
  d->ssl_ca=copy_bytes(ssl_ca); d->plugin_dir=copy_bytes(plugin_dir);
  d->timeout=timeout; d->max_rows=max_rows; d->max_bytes=max_bytes;
  if (pipe2(d->pipefd,O_CLOEXEC)) goto failed;
  if (fcntl(d->pipefd[0],F_SETFL,O_NONBLOCK)<0) goto failed;
  if (pthread_mutex_init(&d->mutex,NULL)) goto failed;
  mutex_ready=1;
  if (pthread_cond_init(&d->cond,NULL)) goto failed;
  cond_ready=1;
  if (pthread_create(&d->thread,NULL,worker,d)) goto failed;
  return d;
failed:
  if (d->pipefd[0]>=0) close(d->pipefd[0]);
  if (d->pipefd[1]>=0) close(d->pipefd[1]);
  if (cond_ready) pthread_cond_destroy(&d->cond);
  if (mutex_ready) pthread_mutex_destroy(&d->mutex);
  free(d->host); free(d->user); explicit_bzero(d->password,strlen(d->password));
  free(d->password); free(d->database); free(d->ssl_ca); free(d->plugin_dir); free(d);
  return NULL;
}
int32_t sk_mysql_fd(Database *d) { return d ? d->pipefd[0] : -1; }
void sk_mysql_reset(Database *d,int32_t count,int32_t transaction) {
  clear_statements(d); clear_result(d); d->transaction=transaction;
  d->statement_count=count; d->statements=alloc(sizeof(Statement)*count);
}
void sk_mysql_statement(Database *d,int32_t index,const uint8_t *sql,int32_t count) {
  Statement *s=&d->statements[index]; s->sql=copy_bytes(sql); s->count=count; s->params=alloc(sizeof(Param)*count);
}
void sk_mysql_param(Database *d,int32_t index,int32_t col,int32_t kind,const uint8_t *data,double number) {
  Param *p=&d->statements[index].params[col]; p->kind=kind; p->data=copy_bytes(data); p->len=Moonbit_array_length(data); p->number=number;
}
void sk_mysql_integer(Database *d,int32_t index,int32_t col,int64_t number) {
  Param *p=&d->statements[index].params[col]; p->kind=4; p->integer=number;
}
void sk_mysql_unsigned(Database *d,int32_t index,int32_t col,uint64_t number) {
  Param *p=&d->statements[index].params[col]; p->kind=5; p->unsigned_integer=number;
}
void sk_mysql_submit(Database *d) { pthread_mutex_lock(&d->mutex); d->pending=1; pthread_cond_signal(&d->cond); pthread_mutex_unlock(&d->mutex); }
// Acquire/release pairs synchronize the completed result with the foreign worker.
int32_t sk_mysql_error(Database *d) { pthread_mutex_lock(&d->mutex); int e=d->error; pthread_mutex_unlock(&d->mutex); return e; }
int32_t sk_mysql_rows(Database *d) { return d->rows; }
int32_t sk_mysql_cols(Database *d) { return d->cols; }
int32_t sk_mysql_kind(Database *d,int32_t col) { return d->kinds[col]; }
int32_t sk_mysql_null(Database *d,int32_t row,int32_t col) { return d->cells[(size_t)row*d->cols+col].null; }
moonbit_bytes_t sk_mysql_name(Database *d,int32_t col) { return text(d->names[col]); }
moonbit_bytes_t sk_mysql_cell(Database *d,int32_t row,int32_t col) { Cell *c=&d->cells[(size_t)row*d->cols+col]; return bytes(c->data,c->len); }
uint64_t sk_mysql_affected(Database *d) { return d->affected; }
uint64_t sk_mysql_insert_id(Database *d) { return d->insert_id; }
void sk_mysql_close(Database *d) {
  pthread_mutex_lock(&d->mutex); d->stopping=1; pthread_cond_signal(&d->cond); pthread_mutex_unlock(&d->mutex);
  pthread_join(d->thread,NULL); close(d->pipefd[1]); // read end belongs to RawFd
  clear_statements(d); clear_result(d); free(d->host); free(d->user);
  explicit_bzero(d->password,strlen(d->password)); free(d->password); free(d->database); free(d->ssl_ca); free(d->plugin_dir);
  pthread_mutex_destroy(&d->mutex); pthread_cond_destroy(&d->cond); free(d);
}
