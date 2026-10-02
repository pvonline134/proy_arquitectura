#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "stats.h"
static float *al(int n){return aligned_alloc(32,((n*4+31)/32+1)*32);}
static int cerca(float a,float r){ if(isinf(a)&&isinf(r)) return 1; return fabsf(a-r)<=1e-4f*fmaxf(1.0f,fabsf(r)); }
int main(void){ int Ns[]={0,1,7,8,15,16,1000,1001}; int fails=0;
 for(int mode=0;mode<3;mode++) for(int k=0;k<8;k++){int n=Ns[k]; float*a=al(n);
  for(int i=0;i<n;i++) a[i]= mode==0?(float)(rand()%20001-10000)/7.0f : mode==1? -3.25f : (i%2?1e30f:-1e30f)*(float)(i%5+1)/5;
  float m=9,v=9,mn=9,mx=9; compute_stats(a,n,&m,&v,&mn,&mx);
  /* referencia en float32, escalar, igual que exige el enunciado */
  float s=0,rmn=n?a[0]:0,rmx=n?a[0]:0; for(int i=0;i<n;i++){s+=a[i]; if(a[i]<rmn)rmn=a[i]; if(a[i]>rmx)rmx=a[i];}
  float rm=n?s/n:0, sq=0; for(int i=0;i<n;i++){float d=a[i]-rm; sq+=d*d;} float rv=n?sq/n:0;
  int ok = (cerca(m,rm)||(mode==2&&n>1)) && mn==rmn && mx==rmx && (cerca(v,rv)||(mode==2&&n>1));
  if(!ok)fails++; printf("modo=%d N=%4d mean=%-12g (ref %-12g) var=%-12g (ref %-12g) min=%g max=%g %s\n",mode,n,m,rm,v,rv,mn,mx,ok?"OK":"FALLA"); free(a);}
 printf(fails?"FALLOS %d\n":"Todo pasa\n",fails); return fails;}
