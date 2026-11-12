#include <stddef.h>
#include <stdint.h>
uint64_t bh_fnv64(const unsigned char *src,size_t n){
 uint64_t h=14695981039346656037ULL;
 for(size_t i=0;i<n;i++)h=(h^src[i])*1099511628211ULL;
 return h;
}
