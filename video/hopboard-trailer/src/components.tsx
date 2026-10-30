import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import {T,ramp} from './theme';

export const Icon:React.FC<{name?:string;size?:number;color?:string}>=({name='copy',size=38,color='currentColor'})=>{
 const paths:Record<string,React.ReactNode>={
 copy:<><rect x="8" y="8" width="13" height="15" rx="2"/><path d="M16 4H5a2 2 0 0 0-2 2v13"/></>,
 check:<path d="m4 12 5 5L21 5"/>,
 wifi:<><path d="M2 8a17 17 0 0 1 20 0M5 12a12 12 0 0 1 14 0M9 16a5 5 0 0 1 6 0"/><circle cx="12" cy="20" r="1"/></>,
 lock:<><rect x="5" y="10" width="14" height="12" rx="2"/><path d="M8 10V6a4 4 0 0 1 8 0v4"/></>,
 folder:<path d="M2 7V4h7l3 3h10v14H2Z"/>,
 file:<><path d="M5 2h9l6 6v14H5Z M14 2v7h6"/><path d="M9 13h7M9 17h7"/></>,
 image:<><rect x="2" y="3" width="20" height="18" rx="2"/><circle cx="8" cy="8" r="2"/><path d="m3 18 6-6 4 4 4-6 5 8"/></>,
 pause:<><path d="M8 4v16M16 4v16"/></>,
 arrow:<path d="M3 12h18m-7-7 7 7-7 7"/>,
 };
 return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">{paths[name]??paths.copy}</svg>;
};
export const Brand:React.FC<{dark?:boolean}>=({dark=false})=><div style={{position:'absolute',left:92,top:56,display:'flex',gap:16,alignItems:'center',fontSize:30,fontWeight:600,color:dark?'#f5f5f7':T.ink}}><Img src={staticFile('branding/icon.png')} style={{width:52,height:52,borderRadius:13}}/>Hopboard</div>;
export const Heading:React.FC<{title:string;sub?:string;dark?:boolean;size?:number;top?:number;maxWidth?:number}>=({title,sub,dark=false,size=86,top=175,maxWidth=1700})=>{
 const f=useCurrentFrame(); const p=ramp(f,3,27);
 return <div style={{position:'absolute',left:92,top,maxWidth,opacity:p,transform:`translateY(${(1-p)*28}px)`}}><div style={{fontSize:size,fontWeight:650,lineHeight:1.06,letterSpacing:-3.5,whiteSpace:'pre-line',color:dark?T.bg:T.ink}}>{title}</div>{sub&&<div style={{fontSize:31,color:dark?'#AEAEB2':T.muted,marginTop:22,lineHeight:1.4}}>{sub}</div>}</div>;
};
export const Caption:React.FC<{text:string;dark?:boolean}>=({text,dark=false})=>{
 const f=useCurrentFrame(); return <div style={{position:'absolute',left:92,right:92,bottom:44,display:'flex',alignItems:'center',gap:21,opacity:ramp(f,6,9),fontSize:74,lineHeight:1.12,fontWeight:400,color:dark?T.bg:T.ink}}><div style={{width:5,height:64,background:dark?T.lightBlue:T.blue,borderRadius:3,flexShrink:0}}/>{text}</div>;
};
export const Window:React.FC<{src:string;style?:React.CSSProperties;dark?:boolean}>=({src,style,dark=false})=><div style={{overflow:'hidden',borderRadius:21,border:`1px solid ${dark?'#3a3a3c':T.line}`,boxShadow:dark?'0 40px 100px #0008':'0 40px 90px #1d1d1f20',background:dark?T.darkSurface:'#fff',...style}}><div style={{height:35,display:'flex',alignItems:'center',padding:'0 16px',gap:8,borderBottom:`1px solid ${dark?'#3a3a3c':T.line}`,color:dark?'#aeaeb2':T.muted,fontSize:14}}><span style={{width:7,height:7,borderRadius:9,background:'#999'}}/><span style={{flex:1}}>Hopboard</span><span>−　□　×</span></div><Img src={staticFile(`textures/${src}.png`)} style={{width:'100%',display:'block'}}/></div>;
export const Surface:React.FC<{children:React.ReactNode;dark?:boolean}>=({children,dark=false})=><AbsoluteFill style={{background:dark?T.dark:T.bg,fontFamily:T.font,color:dark?T.bg:T.ink,overflow:'hidden'}}>{children}</AbsoluteFill>;
export const DevLabel=()=><div style={{position:'absolute',left:94,top:136,fontSize:44,color:T.lightBlue,fontWeight:600,letterSpacing:1.1}}>WINDOWS · DEVELOPMENT PREVIEW</div>;
export const Keycap:React.FC<{text:string;active?:boolean}>=({text,active=false})=><span style={{display:'inline-flex',alignItems:'center',justifyContent:'center',padding:'14px 21px',minWidth:70,borderRadius:12,border:`2px solid ${active?T.blue:'#d1d1d6'}`,background:active?T.blue:'#fff',color:active?'white':T.ink,boxShadow:active?'0 2px 0 #004c99':'0 5px 0 #ddd',fontSize:29,fontWeight:500}}>{text}</span>;
export const Cursor:React.FC<{x:number;y:number;click?:boolean}>=({x,y,click})=><div style={{position:'absolute',left:x,top:y,filter:'drop-shadow(0 4px 5px #0003)'}}>{click&&<div style={{position:'absolute',left:-18,top:-18,width:50,height:50,border:`3px solid ${T.blue}`,borderRadius:100,opacity:.5}}/>}<svg width="32" height="42" viewBox="0 0 32 42"><path d="M3 2v32l8-8 7 13 7-4-7-12h12Z" fill="#1d1d1f" stroke="white" strokeWidth="2"/></svg></div>;
export const Device:React.FC<{name:string;kind?:'laptop'|'pc'|'phone';x:number;y:number;scale?:number;children?:React.ReactNode;dark?:boolean}>=({name,kind='laptop',x,y,scale=1,children,dark=false})=>{
 const phone=kind==='phone'; const w=phone?220:480,h=phone?380:286;
 return <div style={{position:'absolute',left:x,top:y,width:w,transform:`scale(${scale})`,transformOrigin:'50% 50%'}}><div style={{height:h,background:dark?'#1c1c1e':'#fff',border:`${phone?8:7}px solid ${dark?'#606065':'#34343a'}`,borderRadius:phone?30:18,overflow:'hidden',position:'relative',boxShadow:'0 18px 45px #00000015'}}>{phone?<div style={{position:'absolute',top:8,left:'35%',width:'30%',height:9,borderRadius:9,background:'#34343a'}}/>:<div style={{height:24,borderBottom:`1px solid ${T.line}`,background:'#f5f5f7'}}/>}{children}</div>{kind==='laptop'?<div style={{height:16,background:'#b8b8be',borderRadius:'0 0 18px 18px',margin:'0 -22px'}}/>:kind==='pc'?<><div style={{height:40,width:42,margin:'auto',background:'#aaaab0'}}/><div style={{height:12,width:150,margin:'auto',background:'#b8b8be',borderRadius:8}}/></>:null}<div style={{textAlign:'center',marginTop:25,fontSize:29,fontWeight:600}}>{name}</div></div>;
};
