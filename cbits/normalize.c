#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
static int token(unsigned char c) {
 switch(c){case '\n':return 'n';case '\r':return 'r';case '\t':return 't';case '\b':return 'b';case '\f':return 'f';case '\\':return '\\';case '"':return '"';case '/':return '/';default:return -1;}
}
static int unescape(unsigned char c) {
 switch(c){case 'n':return '\n';case 'r':return '\r';case 't':return '\t';case 'b':return '\b';case 'f':return '\f';case '\\':return '\\';case '"':return '"';case '/':return '/';default:return -1;}
}
size_t bh_normalize(const unsigned char *src,size_t n,unsigned char *dst,size_t capacity) {
 if(n>67108864 || capacity<n+(n+7)/8+4) return SIZE_MAX;
 unsigned char *flags=calloc((n+7)/8+1,1); if(!flags) return SIZE_MAX;
 size_t pos=0,main=0,bits=0;
 while(pos<n){
  unsigned char c=src[pos++];int escaped=0;
  if(c=='\\'&&pos<n){int t=unescape(src[pos]);if(t>=0){c=(unsigned char)t;pos++;escaped=1;}}
  dst[4+main++]=c;
  if(token(c)>=0){if(escaped)flags[bits>>3]|=(unsigned char)(1u<<(bits&7));bits++;}
 }
 for(unsigned i=0;i<4;i++)dst[i]=(unsigned char)(main>>(8*i));
 size_t bytes=(bits+7)/8;memcpy(dst+4+main,flags,bytes);free(flags);return 4+main+bytes;
}
size_t bh_denormalize(const unsigned char *src,size_t n,unsigned char *dst,size_t wanted) {
 if(n<4||n>67108864||wanted>67108864)return SIZE_MAX;
 uint32_t main=0;for(unsigned i=0;i<4;i++)main|=((uint32_t)src[i])<<(8*i);
 if(main>n-4)return SIZE_MAX;
 const unsigned char *flags=src+4+main;size_t flagbytes=n-4-main,bits=0,out=0;
 for(size_t pos=0;pos<main;pos++){
  unsigned char c=src[4+pos];int t=token(c),escaped=0;
  if(t>=0){if((bits>>3)>=flagbytes)return SIZE_MAX;escaped=(flags[bits>>3]>>(bits&7))&1;bits++;}
  if(escaped){if(wanted-out<2)return SIZE_MAX;dst[out++]='\\';dst[out++]=(unsigned char)t;}
  else{if(out>=wanted)return SIZE_MAX;dst[out++]=c;}
 }
 if((bits+7)/8!=flagbytes || out!=wanted)return SIZE_MAX;
 if((bits&7)&&flagbytes&&(flags[flagbytes-1]>>(bits&7)))return SIZE_MAX;
 return out;
}
