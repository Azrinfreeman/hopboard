import {Easing, interpolate} from 'remotion';
export const T = {bg:'#F5F5F7',surface:'#FFFFFF',ink:'#1D1D1F',muted:'#636366',blue:'#0066CC',lightBlue:'#409CFF',line:'#E5E5EA',dark:'#101012',darkSurface:'#1C1C1E',green:'#207442',font:'"Segoe UI", sans-serif',fps:30,width:1920,height:1080};
export const ease=Easing.bezier(.22,1,.36,1);
export const ramp=(f:number,start=0,length=26,easing=ease)=>interpolate(f,[start,start+length],[0,1],{extrapolateLeft:'clamp',extrapolateRight:'clamp',easing});
export const mix=(f:number,a:number,b:number,x:number,y:number)=>interpolate(f,[a,b],[x,y],{extrapolateLeft:'clamp',extrapolateRight:'clamp',easing:ease});
