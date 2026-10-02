#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "stats.h"
int main(void){
  int Ns[]={0,1,7,8,15,16,1000,1001}; int fails=0;
  for(int k=0;k<8;k++){ int n=Ns[k];
    float *in=aligned_alloc(32,((n*4+31)/32+1)*32), *out=aligned_alloc(32,((n*4+31)/32+1)*32);
    for(int i=0;i<n;i++) in[i]=(float)(rand()%20001-10000)/7.0f;
    float mean=3.5f, sd=12.25f;
    normalize_array(in,out,n,mean,sd);
    for(int i=0;i<n;i++){ float r=(in[i]-mean)/sd; if(fabsf(out[i]-r)>1e-6f*fmaxf(1,fabsf(r))){fails++; break;} }
    normalize_array(in,out,n,mean,0.0f);
    for(int i=0;i<n;i++) if(out[i]!=in[i]){fails++;break;}
    float s=sum_array(in,n), rs=0; for(int i=0;i<n;i++) rs+=in[i];
    printf("N=%4d  normaliza OK, copia(std=0) OK, suma=%.4f ref=%.4f\n",n,s,rs);
    free(in);free(out);}
  printf(fails?"FALLOS: %d\n":"Todo pasa\n",fails); return fails;}
