/* Standalone deterministic roundtrip + malformed-frame stress test.
 * Compile with ASan/UBSan; no corpus or private files required. */
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
size_t bh_normalize(const unsigned char*,size_t,unsigned char*,size_t);
size_t bh_denormalize(const unsigned char*,size_t,unsigned char*,size_t);
size_t bh_tokenize(const unsigned char*,size_t,unsigned char*,size_t);
size_t bh_detokenize(const unsigned char*,size_t,unsigned char*,size_t);
static uint32_t seed=7261;
static unsigned rnd(void){seed=1664525u*seed+1013904223u;return seed;}
int main(void){
 unsigned char src[4096],encoded[16384],out[8192];
 for(unsigned round=0;round<1500;round++){
  size_t n=rnd()%sizeof(src);
  for(size_t i=0;i<n;i++)src[i]=(unsigned char)(round%3==0 ? rnd()%256 : (unsigned char)"abc_identifier0123 \\n\n\t\"/"[rnd()%25]);
  size_t k=bh_normalize(src,n,encoded,sizeof(encoded));assert(k!=SIZE_MAX);
  assert(bh_denormalize(encoded,k,out,n)==n && !memcmp(src,out,n));
  k=bh_tokenize(src,n,encoded,sizeof(encoded));assert(k!=SIZE_MAX);
  assert(bh_detokenize(encoded,k,out,n)==n && !memcmp(src,out,n));
  if(k) {encoded[rnd()%k]^=(unsigned char)(1u<<(rnd()%8)); (void)bh_detokenize(encoded,k,out,rnd()%sizeof(out));}
  size_t m=rnd()%sizeof(encoded);
  for(size_t i=0;i<m;i++)encoded[i]=(unsigned char)rnd();
  (void)bh_denormalize(encoded,m,out,rnd()%sizeof(out));
  (void)bh_detokenize(encoded,m,out,rnd()%sizeof(out));
  if(m>=4){encoded[0]=rnd()%16;encoded[1]=encoded[2]=encoded[3]=0;
   (void)bh_denormalize(encoded,m,out,rnd()%sizeof(out));
   (void)bh_detokenize(encoded,m,out,rnd()%sizeof(out));}
 }
 puts("1500 native roundtrip/malformed rounds passed");return 0;
}
