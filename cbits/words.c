#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#define LIMIT 67108864u
#define SLOTS 262144u
#define MASK (SLOTS-1)
typedef struct {const unsigned char *word; uint64_t hash; uint32_t len,count,id;} Word;
static int isword(unsigned c){return ((c|32u)-97u)<=25u || (c-48u)<=9u || c==95 || c==36;}
static uint64_t hashword(const unsigned char *p,size_t n){uint64_t h=14695981039346656037ULL;for(size_t i=0;i<n;i++)h=(h^p[i])*1099511628211ULL;return h;}
static Word *lookup(Word *table,const unsigned char *p,size_t n,uint64_t hash,int create,size_t *used){
 for(unsigned j=0;j<64;j++){
  Word *w=&table[(hash+j)&MASK];
  if(!w->word){if(!create||*used>=SLOTS*3/4)return NULL;w->word=p;w->len=(uint32_t)n;w->hash=hash;(*used)++;return w;}
  if(w->hash==hash&&w->len==n&&!memcmp(w->word,p,n))return w;
 }
 return NULL;
}
static int64_t gain(const Word *w){return ((int64_t)w->len-1)*w->count-(w->len+2);}
static int64_t widegain(const Word *w){return ((int64_t)w->len-3)*w->count-(w->len+2);}
static int compare(const void *a,const void *b){
 const Word *x=*(Word *const *)a,*y=*(Word *const *)b;int64_t gx=gain(x),gy=gain(y);
 if(gx!=gy)return gx>gy?-1:1;
 int order=memcmp(x->word,y->word,x->len<y->len?x->len:y->len);
 return order?order:(x->len>y->len)-(x->len<y->len);
}
static int widecompare(const void *a,const void *b){
 const Word *x=*(Word *const *)a,*y=*(Word *const *)b;int64_t gx=widegain(x),gy=widegain(y);
 return gx==gy?compare(a,b):(gx>gy?-1:1);
}
size_t bh_tokenize(const unsigned char *src,size_t n,unsigned char *dst,size_t cap){
 if(n>LIMIT||cap<4)return SIZE_MAX;
 Word *table=calloc(SLOTS,sizeof(Word));Word **selected=malloc((SLOTS*3/4)*sizeof(Word*));
 if(!table||!selected){free(table);free(selected);return SIZE_MAX;}
 size_t used=0,count=0;
 for(size_t i=0;i<n;){
  if(!isword(src[i])){i++;continue;}size_t start=i;while(i<n&&isword(src[i]))i++;size_t len=i-start;
  if(len>=3&&len<=128){Word *w=lookup(table,src+start,len,hashword(src+start,len),1,&used);if(w)w->count++;}
 }
 for(size_t i=0;i<SLOTS;i++)if(table[i].word&&gain(&table[i])>0)selected[count++]=&table[i];
 qsort(selected,count,sizeof(Word*),compare);if(count>128){qsort(selected+128,count-128,sizeof(Word*),widecompare);size_t keep=128;while(keep<count&&keep<32640&&widegain(selected[keep])>0)keep++;count=keep;}
 for(unsigned i=0;i<4;i++)dst[i]=(unsigned char)(count>>(8*i));
 size_t out=4;
 for(size_t i=0;i<count;i++){
  Word *w=selected[i];if(w->len+2>cap-out)goto fail;
  w->id=(uint32_t)i+1;dst[out++]=(unsigned char)w->len;dst[out++]=(unsigned char)(w->len>>8);
  memcpy(dst+out,w->word,w->len);out+=w->len;
 }
 for(size_t i=0;i<n;){
  if(isword(src[i])){
   size_t start=i;while(i<n&&isword(src[i]))i++;size_t len=i-start;Word *w=NULL;
   if(len>=3&&len<=128)w=lookup(table,src+start,len,hashword(src+start,len),0,&used);
   if(w&&w->id){if(w->id<=128){if(out>=cap)goto fail;dst[out++]=(unsigned char)(127+w->id);}else{if(cap-out<3)goto fail;uint32_t code=w->id-129;dst[out++]=127;dst[out++]=(unsigned char)(code>>8);dst[out++]=(unsigned char)code;}}
   else {if(len>cap-out)goto fail;memcpy(dst+out,src+start,len);out+=len;}
  }else{
   unsigned c=src[i++];if(cap-out<(c<127?1u:2u))goto fail;if(c>=127)dst[out++]=127;dst[out++]=(unsigned char)c;
  }
 }
 free(selected);free(table);return out;
fail:free(selected);free(table);return SIZE_MAX;
}
size_t bh_detokenize(const unsigned char *src,size_t n,unsigned char *dst,size_t wanted){
 if(n<4||n>LIMIT||wanted>LIMIT)return SIZE_MAX;
 uint32_t count=0;for(unsigned i=0;i<4;i++)count|=((uint32_t)src[i])<<(8*i);if(count>32640)return SIZE_MAX;
 Word *words=calloc((size_t)count+1,sizeof(Word));if(!words)return SIZE_MAX;
 size_t pos=4,out=0;
 for(uint32_t i=1;i<=count;i++){
  if(n-pos<2)goto fail;
  uint32_t len=src[pos]|((uint32_t)src[pos+1]<<8);pos+=2;
  if(len<3||len>128||len>n-pos)goto fail;
  for(unsigned j=0;j<len;j++)if(!isword(src[pos+j]))goto fail;
  words[i].word=src+pos;words[i].len=len;pos+=len;
 }
 while(pos<n){
  unsigned c=src[pos++];uint32_t id=0;
  if(c<127){if(out>=wanted)goto fail;dst[out++]=(unsigned char)c;continue;}
  if(c>127)id=c-127;
  else{if(pos>=n)goto fail;unsigned next=src[pos++];if(next>=127){if(out>=wanted)goto fail;dst[out++]=(unsigned char)next;continue;}if(pos>=n)goto fail;id=129+next*256+src[pos++];}
  if(id>count)goto fail;
  size_t len=words[id].len;if(len>wanted-out)goto fail;memcpy(dst+out,words[id].word,len);out+=len;
 }

 free(words);return out==wanted?out:SIZE_MAX;
fail:free(words);return SIZE_MAX;
}
