import React from 'react';
import {AbsoluteFill,Easing,Img,interpolate,staticFile,useCurrentFrame} from 'remotion';
import {T,ramp,mix,ease} from './theme';
import {Brand,Heading,Caption,Window,Surface,DevLabel,Keycap,Cursor,Device,Icon} from './components';
import {PageCam} from './PageCam';
export type SceneProps={title?:string;caption?:string;duration?:number};
const packetStyle:React.CSSProperties={padding:'24px 30px',background:'#EDF5FF',border:`1px solid #bad8f5`,borderRadius:14,color:T.blue,fontSize:25,lineHeight:1.4};

export const Intro:React.FC<SceneProps>=({title='Your clipboard.\nAcross your devices.',caption='A shared clipboard for your nearby devices.'})=>{
 const f=useCurrentFrame(); const t=ramp(f,12,90);
 return <Surface><Brand/><Heading title={title} top={276} size={99} maxWidth={700}/><div style={{position:'absolute',left:95,top:652,color:T.muted,fontSize:44}}>Copy once. Keep going.</div><div style={{position:'absolute',left:835,top:235,width:1030,height:690,transform:`perspective(1800px) rotateY(${-12+10*t}deg) rotateX(${3-3*t}deg) translateY(${(1-t)*60}px)`,opacity:ramp(f,12,25)}}><Window src="clipboard"/></div><Caption text={caption}/></Surface>;
};

export const Network:React.FC<SceneProps>=({title='Copy here. Paste there.',caption='Same Wi-Fi. No account. No cloud. No internet required.'})=>{
 const f=useCurrentFrame(); const t=ramp(f,40,50);
 return <Surface><Brand/><Heading title={title} sub="A shared clipboard over your local network."/>
 <div style={{position:'absolute',left:98,top:358,width:1724,height:513,border:'2px dashed #bfd5eb',borderRadius:44,background:'#edf5ff66'}}/>
 <div style={{position:'absolute',left:790,top:329,background:T.bg,padding:'10px 25px',display:'flex',gap:15,alignItems:'center',fontSize:27,color:T.blue}}><Icon name="wifi" size={30}/>Local Wi-Fi</div>
 <svg style={{position:'absolute',inset:0}} width="1920" height="1080"><path d="M620 575H820M1300 575H1452" stroke="#afcbe8" strokeWidth="4" strokeDasharray="8 8"/></svg>
 <Device name="Work laptop" x={150} y={440}><div style={{padding:26,fontSize:25,color:T.muted}}>Copied text<div style={{...packetStyle,marginTop:22}}>The next idea starts here.</div></div></Device>
 <Device name="Studio PC" kind="pc" x={820} y={440}><div style={{padding:26,fontSize:25,color:T.muted}}>Shared clipboard<div style={{...packetStyle,marginTop:22,opacity:ramp(f,76,16)}}>The next idea starts here.</div></div></Device>
 <Device name="Android" kind="phone" x={1510} y={406}><div style={{padding:'60px 18px 0',fontSize:22,color:T.muted}}>Hopboard<div style={{...packetStyle,padding:15,fontSize:21,marginTop:26,opacity:ramp(f,99,15)}}>Available<br/>in app</div></div></Device>
 <div style={{position:'absolute',left:620+200*t,top:557,width:19,height:19,borderRadius:20,background:T.blue,opacity:interpolate(f,[38,43,85,92],[0,1,1,0],{extrapolateLeft:'clamp',extrapolateRight:'clamp'})}}/>
 <Caption text={caption}/></Surface>;
};

export const Pair:React.FC<SceneProps>=({title='Pair once.',caption='Join the host with its six-digit code.'})=>{
 const f=useCurrentFrame();
 return <Surface><Brand/><Heading title={title} top={175} size={96}/>
 <div style={{position:'absolute',left:110,top:323,fontSize:44,lineHeight:1.3}}><strong>Host PC</strong><div style={{color:T.blue}}>Start session ? Add device</div></div>
 <Img src={staticFile('textures/host-code.png')} style={{position:'absolute',left:110,top:463,width:520,borderRadius:20,boxShadow:'0 20px 60px #0002',opacity:ramp(f,8,24)}}/>
 <div style={{position:'absolute',left:900,top:173,fontSize:44,lineHeight:1.3}}><strong>Other device</strong><div style={{color:T.blue}}>Enter pairing code</div><div style={{color:T.muted}}>Select host ? enter code ? Connect</div></div>
 <Img src={staticFile('textures/join-dialog.png')} style={{position:'absolute',left:1015,top:390,width:510,borderRadius:20,boxShadow:'0 20px 60px #0002',opacity:ramp(f,35,24)}}/>
 <div style={{position:'absolute',left:94,top:885,fontSize:44,color:T.muted}}>Same Wi-Fi ? allow Private-network access</div>
 <Caption text={caption}/></Surface>;
};

export const Approve:React.FC<SceneProps>=({title='You’re in control.',caption='Approve the device, then choose automatic sharing.'})=>{
 const f=useCurrentFrame(); const approved=f>=45;
 return <Surface><Brand/><Heading title={title} sub="Only the devices you approve can join."/>
 <div style={{position:'absolute',left:110,top:390,width:590,height:394,background:'white',borderRadius:26,padding:38,border:`1px solid ${T.line}`,boxShadow:'0 24px 60px #0000000c'}}><div style={{display:'flex',gap:18,alignItems:'center',fontSize:28,color:T.muted}}><Icon name="lock" color={T.blue}/>Illustrated approval</div><div style={{fontSize:46,fontWeight:600,marginTop:33}}>Work laptop</div><div style={{marginTop:36,height:69,background:approved?'#e7f5eb':T.blue,color:approved?T.green:'white',borderRadius:13,display:'flex',gap:16,alignItems:'center',justifyContent:'center',fontSize:29}}><Icon name={approved?'check':'lock'} size={28}/>{approved?'Trusted device':'Approve device'}</div></div>
 <div style={{position:'absolute',left:775,top:397,width:1030}}><div style={{fontSize:28,color:T.muted,marginBottom:28}}>In Hopboard</div><div style={{position:'relative'}}><Img src={staticFile('textures/auto-control.png')} style={{width:'100%',borderRadius:19,border:`2px solid ${T.line}`,boxShadow:'0 20px 55px #0000000d'}}/>{f<88&&<div style={{position:'absolute',right:20,top:20,width:80,height:44,borderRadius:44,background:'#d1d1d6'}}><div style={{position:'absolute',left:5,top:5,width:34,height:34,background:'white',borderRadius:40}}/></div>}</div><div style={{fontSize:44,lineHeight:1.4,marginTop:40,width:900,opacity:ramp(f,75,23)}}>Enable automatic text sharing.<br/><span style={{color:T.muted}}>New copies sync to connected devices.</span></div></div>
 <Cursor x={f<65?mix(f,20,44,380,450):mix(f,65,88,450,1750)} y={f<65?mix(f,20,44,860,655):mix(f,65,88,655,460)} click={(f>=44&&f<51)||(f>=88&&f<94)}/><Caption text={caption}/></Surface>;
};

export const Copy:React.FC<SceneProps>=({title='Copy on your laptop.',caption='Copy a link, a note, or the next big idea.'})=>{
 const f=useCurrentFrame();const selected=f>=43; const copied=f>=70;
 return <Surface><Brand/><Heading title={title}/><div style={{position:'absolute',left:235,top:370,width:1450,height:490,background:'white',border:`1px solid ${T.line}`,borderRadius:24,boxShadow:'0 28px 65px #00000012',overflow:'hidden'}}><div style={{height:62,background:'#eeeef1',padding:'16px 30px',fontSize:23,color:T.muted}}>Project notes <span style={{float:'right'}}>Illustrated workflow</span></div><div style={{padding:'50px 65px'}}><div style={{fontSize:28,color:T.muted,marginBottom:30}}>Launch ideas</div><span style={{fontSize:55,fontWeight:500,letterSpacing:-1.2,background:selected?'#c6dfff':'transparent'}}>The next idea starts here.</span><div style={{fontSize:29,color:T.muted,marginTop:35}}>Pick up where you left off, on another device.</div></div></div><div style={{position:'absolute',left:1440,top:772,display:'flex',gap:12}}><Keycap text="Ctrl" active={copied}/><Keycap text="C" active={copied}/></div><div style={{position:'absolute',left:300,top:770,fontSize:28,color:T.green,display:'flex',alignItems:'center',gap:12,opacity:ramp(f,73,12)}}><Icon name="check" size={26}/>Copied</div><Cursor x={mix(f,20,43,420,1100)} y={535} click={f>=43&&f<50}/><Caption text={caption}/></Surface>;
};

export const Paste:React.FC<SceneProps>=({title='Keep going on your PC.',caption='Local transfer. Your text is ready to paste.'})=>{
 const f=useCurrentFrame();const packet=ramp(f,28,55);const received=f>=88;
 return <Surface><Brand/><Heading title={title}/><Device name="Work laptop" x={200} y={402}><div style={{padding:35,fontSize:29,color:T.muted}}>Copied<div style={{...packetStyle,marginTop:25}}>The next idea starts here.</div></div></Device><Device name="Studio PC" kind="pc" x={1240} y={402}><div style={{padding:35,fontSize:29,color:T.muted}}>Your document<div style={{marginTop:25,color:T.ink,fontSize:29,lineHeight:1.4,opacity:ramp(f,90,18)}}>The next idea starts here.<span style={{color:T.blue}}>│</span></div></div></Device><div style={{position:'absolute',left:770,top:420,width:380,textAlign:'center',color:T.blue}}><Icon name="wifi" size={42}/><div style={{fontSize:24,marginTop:15}}>Your local network</div></div><svg width="1920" height="1080" style={{position:'absolute',inset:0}}><path d="M700 610H1210" stroke="#b4cee8" strokeWidth="3" strokeDasharray="7 8"/></svg><div style={{position:'absolute',left:700+510*packet,top:583,background:T.blue,color:'white',borderRadius:14,padding:13,opacity:interpolate(f,[26,32,79,88],[0,1,1,0],{extrapolateLeft:'clamp',extrapolateRight:'clamp'})}}><Icon size={30}/></div><div style={{position:'absolute',left:1390,top:813,display:'flex',gap:12}}><Keycap text="Ctrl" active={received}/><Keycap text="V" active={received}/></div><div style={{position:'absolute',left:812,top:700,fontSize:27,color:T.green,display:'flex',alignItems:'center',gap:12,opacity:ramp(f,83,15)}}><Icon name="check" size={28}/>Ready to paste</div><Caption text={caption}/></Surface>;
};

export const Phone:React.FC<SceneProps>=({title='Your phone joins in.',caption='Android: keep Hopboard open. Paste & Send, or Copy.'})=>{
 const f=useCurrentFrame(); return <Surface><Brand/><Heading title={title} top={240} maxWidth={850} size={95}/><div style={{position:'absolute',left:96,top:410,width:740,fontSize:44,lineHeight:1.55,color:T.muted}}>Use the shared clipboard<br/>while the app is in front.</div><div style={{position:'absolute',left:96,top:600,display:'flex',gap:22,opacity:ramp(f,30,25)}}>{['Paste & Send','Copy'].map(s=><div key={s} style={{padding:'23px 32px',background:s==='Copy'?'white':T.blue,color:s==='Copy'?T.blue:'white',border:`1px solid ${T.line}`,borderRadius:16,fontSize:44}}>{s}</div>)}</div><div style={{position:'absolute',left:1080,top:153,width:358,height:775,border:'9px solid #34343a',borderRadius:43,overflow:'hidden',background:'white',boxShadow:'0 40px 80px #0002',transform:`translateY(${(1-ramp(f,8,50))*70}px)`}}><Img src={staticFile('textures/phone.png')} style={{width:'100%'}}/></div><div style={{position:'absolute',left:1498,top:430,fontSize:29,width:280,lineHeight:1.45,color:T.blue,opacity:ramp(f,65,25)}}>Windows ↔ Android<br/><span style={{color:T.muted,fontSize:44}}>Text sharing</span></div><Caption text={caption}/></Surface>;
};

export const Artwork=()=> <svg viewBox="0 0 700 450" width="100%" height="100%"><defs><linearGradient id="sky" x2="0" y2="1"><stop stopColor="#bcdcf4"/><stop offset="1" stopColor="#edf5ff"/></linearGradient></defs><rect width="700" height="450" fill="url(#sky)"/><circle cx="520" cy="120" r="55" fill="#fff"/><path d="M0 340 180 125 430 450H0" fill="#0066cc"/><path d="m200 450 290-290 210 230v60" fill="#409cff"/><path d="m345 305 145-145 67 124-71-28-58 54-37-20" fill="#f5f5f7"/><path d="M0 410q190-60 370 15t330-5v30H0" fill="#18375b"/></svg>;
export const ImageScene:React.FC<SceneProps>=({title='Beyond text.',caption='Windows development builds also share images.'})=>{
 const f=useCurrentFrame(); const t=ramp(f,15,75);
 return <Surface dark><Brand dark/><DevLabel/><Heading title={title} dark top={300} size={106} maxWidth={680}/><div style={{position:'absolute',left:96,top:470,fontSize:37,color:'#aeaeb2',lineHeight:1.45}}>Copy an image.<br/>Use it on another PC.</div><div style={{position:'absolute',left:900,top:295,width:760,height:489,transform:`perspective(1700px) rotateY(${-16+12*t}deg) rotateZ(${-4+4*t}deg)`,border:'10px solid white',borderRadius:24,overflow:'hidden',boxShadow:'18px 30px 0 #2c2c2e, 35px 65px 75px #0008'}}><Artwork/></div><div style={{position:'absolute',left:1140,top:846,display:'flex',alignItems:'center',gap:18,fontSize:27,color:T.lightBlue}}><Icon name="image"/>Windows image sharing</div><Caption text={caption} dark/></Surface>;
};

export const Files:React.FC<SceneProps>=({title='Files. Folders. ZIPs.',caption='Download. Verify. Ready to paste.'})=>{
 const f=useCurrentFrame();const verified=f>=90;const downloading=f>=45;
 return <Surface dark><Brand dark/><DevLabel/><Heading title={title} top={225} dark size={86}/>
 <div style={{position:'absolute',left:100,top:405,width:555}}>{[['folder','Project assets'],['file','Launch.zip'],['file','Presentation.pdf']].map(([icon,name],i)=><div key={name} style={{display:'flex',alignItems:'center',gap:24,fontSize:44,padding:'26px 0',borderBottom:'1px solid #3a3a3c',opacity:ramp(f,15+i*10,22)}}><Icon name={icon} color={T.lightBlue}/>{name}</div>)}<div style={{marginTop:30,fontSize:40,lineHeight:1.4,color:'#aeaeb2'}}>Choose files or a folder.<br/>Or use Explorer Copy.</div></div>
 <div style={{position:'absolute',left:790,top:360,width:1035,height:535,borderRadius:25,overflow:'hidden',border:'1px solid #3a3a3c',background:'#1c1c1e'}}>
 <Img src={staticFile('textures/files-download.png')} style={{position:'absolute',width:1035,top:-200,opacity:.2}}/>
 <div style={{position:'absolute',inset:0,padding:'32px 42px',background:'#1c1c1eea'}}>
 <div style={{fontSize:40,color:'#aeaeb2'}}>Transfer workflow ? illustration</div>
 <div style={{marginTop:40,display:'flex',gap:22,alignItems:'center',fontSize:48}}><Icon name="folder" size={52} color={T.lightBlue}/>Project assets</div>
 <div style={{marginTop:35,height:9,borderRadius:12,background:'#3a3a3c',overflow:'hidden'}}><div style={{height:'100%',width:`${100*ramp(f,45,40)}%`,background:verified?'#82d39c':T.lightBlue}}/></div>
 <div style={{marginTop:36,fontSize:58,color:verified?'#82d39c':T.bg,display:'flex',gap:20,alignItems:'center'}}><Icon name={verified?'check':'file'} size={52}/>{verified?'Ready to paste':downloading?'Downloading & verifying':'Download'}</div>
 <div style={{marginTop:20,fontSize:40,color:'#aeaeb2'}}>{verified?'Copy files ? paste in Explorer':'Your file is checked before clipboard use.'}</div>
 </div></div><Caption text={caption} dark/></Surface>;
};

export const Consent:React.FC<SceneProps>=({title='Choose what shares.',caption='Images and files each need separate permission.'})=>{
 const f=useCurrentFrame(); return <Surface><Brand/><Heading title={title} sub="Automatic sharing is your choice."/>
 <div style={{position:'absolute',left:280,top:395,width:1360,background:'white',padding:'10px 50px',borderRadius:24,border:`1px solid ${T.line}`}}>{[['copy','Text','Enable automatic sharing'],['image','Images','Separate permission'],['folder','Files & folders','Separate permission']].map(([icon,name,note],i)=><div key={name} style={{height:150,display:'flex',alignItems:'center',gap:30,borderBottom:i<2?`1px solid ${T.line}`:undefined,opacity:ramp(f,10+i*14,25)}}><Icon name={icon} color={T.blue} size={43}/><div style={{flex:1,fontSize:36,fontWeight:600}}>{name}<div style={{fontSize:25,color:T.muted,fontWeight:400,marginTop:9}}>{note}</div></div><div style={{width:86,height:49,borderRadius:40,background:i===0?T.blue:'#d1d1d6',position:'relative'}}><div style={{position:'absolute',width:39,height:39,borderRadius:30,background:'white',top:5,left:i===0?42:5,boxShadow:'0 2px 4px #0002'}}/></div></div>)}</div><div style={{position:'absolute',right:286,top:865,fontSize:22,color:T.muted}}>Sharing controls · illustration</div><Caption text={caption}/></Surface>;
};

export const Extras:React.FC<SceneProps>=({title='The useful little things.',caption='Tray controls. Trusted devices. System themes.'})=>{
 const f=useCurrentFrame(); const cols=[{title:'Pause from the tray',sub:'Keep sharing within reach.'},{title:'Reconnect trusted devices',sub:'Pair once. Return when needed.'},{title:'Light. Dark. High contrast.',sub:'Follow your system preferences.'}];
 return <Surface><Brand/><Heading title={title} size={84}/>{cols.map((c,i)=><div key={c.title} style={{position:'absolute',left:92+i*590,top:380,width:555,opacity:ramp(f,10+i*9,25),transform:`translateY(${(1-ramp(f,10+i*9,25))*30}px)`}}><div style={{height:370,background:i===2?T.dark:'white',borderRadius:23,border:`1px solid ${T.line}`,overflow:'hidden',position:'relative'}}>{i===0?<><div style={{height:42,background:'#e5e5ea',padding:'8px 22px',fontSize:20}}>Windows tray · illustration</div><div style={{padding:'35px 40px',fontSize:31,lineHeight:1.8}}><div style={{display:'flex',alignItems:'center',gap:16}}><Img src={staticFile('branding/icon.png')} style={{width:40,borderRadius:9}}/>Hopboard</div><div style={{color:T.blue,marginTop:23,display:'flex',alignItems:'center',gap:17}}><Icon name="pause" size={28}/>Pause sharing</div><div style={{color:T.muted}}>Open　　Quit</div></div></>:i===1?<Img src={staticFile('textures/devices.png')} style={{position:'absolute',width:1100,left:-80,top:-85}}/>:<><Img src={staticFile('textures/clipboard-dark.png')} style={{width:790,position:'absolute',left:-80,top:0}}/><Img src={staticFile('textures/clipboard.png')} style={{position:'absolute',width:640,left:165,top:175,borderRadius:14,boxShadow:'0 0 0 3px #aaa'}}/></>}</div><div style={{fontSize:44,fontWeight:600,marginTop:27,lineHeight:1.2}}>{c.title}</div></div>)}<Caption text={caption}/></Surface>;
};

// Adapted from video-shotcraft's exact OutroGroupPhotoLaunch demo. Brand and
// screenshots replaced; cue timing, overshoot, crane, recede and stamp retained.
export const Outro:React.FC<SceneProps>=({title='Hopboard',caption='Your devices. One local clipboard.',duration=150})=>{
 const f=useCurrentFrame(); const crane=ramp(f,0,40,Easing.bezier(.3,0,.2,1));const recede=ramp(f,42,8); const fly=Easing.bezier(.34,1.4,.44,1);
 const elements=[{src:'auto-control',x:750,y:156,w:690,h:64,dx:0,dy:-240,rot:-2},{src:'text-card',x:115,y:265,w:510,h:202,dx:-500,dy:0,rot:-4},{src:'file-card',x:1325,y:300,w:470,h:187,dx:500,dy:0,rot:4},{src:'device-list',x:130,y:745,w:565,h:254,dx:-400,dy:300,rot:2},{src:'clipboard-dark',x:1340,y:770,w:500,h:312,dx:400,dy:280,rot:-3},{src:'pair-card',x:810,y:800,w:335,h:404,dx:0,dy:380,rot:2}];
 return <Surface><AbsoluteFill style={{transform:`perspective(1400px) rotateX(${4*(1-crane)}deg) scale(${1.06-.06*crane})`}}><AbsoluteFill style={{background:'radial-gradient(ellipse at 50% 45%,#e3efff 0%,#f5f5f7 65%)'}}/>{elements.map((el,i)=>{const cue=4+i*3;const t=ramp(f,cue,12,fly);const land=interpolate(f,[cue+9,cue+12,cue+16],[0,1,0],{extrapolateLeft:'clamp',extrapolateRight:'clamp'});return <div key={el.src} style={{position:'absolute',left:el.x,top:el.y,width:el.w,height:el.h,opacity:ramp(f,cue,3)*(1-.12*recede),transform:`translate(${el.dx*(1-t)}px,${el.dy*(1-t)}px) rotate(${el.rot*(2-t)}deg) scale(${(1.12-.12*t)*(1-.015*land)})`,borderRadius:15,overflow:'hidden',boxShadow:`0 ${10+26*Math.max(0,1-t)}px ${24+46*Math.max(0,1-t)}px #1d1d1f24`,filter:`saturate(${1-.08*recede}) blur(${Math.max(0,(1-t)*4)}px)`}}><Img src={staticFile(`textures/${el.src}.png`)} style={{width:'100%',height:'100%',objectFit:'cover'}}/></div>})}</AbsoluteFill>
 <AbsoluteFill style={{background:'radial-gradient(ellipse 720px 250px at 50% 48%,#ffffffee 20%,#f5f5f700 100%)',opacity:ramp(f,42,12)}}/>
 <div style={{position:'absolute',left:0,right:0,top:399,display:'flex',justifyContent:'center',alignItems:'center',gap:32}}><Img src={staticFile('branding/icon.png')} style={{width:142,height:142,borderRadius:31,opacity:ramp(f,38,8),transform:`translateY(${28*(1-ramp(f,38,8))}px) scale(${1.35-.35*ramp(f,38,8)})`}}/><div style={{fontSize:130,fontWeight:650,letterSpacing:-4,lineHeight:1.2}}>{title.split('').map((ch,i)=>{const t=ramp(f,Math.round(42+i*1.8),8,Easing.bezier(.2,.75,.3,1));return <span key={i} style={{display:'inline-block',opacity:t,transform:`translateY(${28*(1-t)}px) scale(${1.35-.35*t})`,filter:`blur(${8*(1-t)}px)`}}>{ch}</span>})}</div></div>
 <div style={{position:'absolute',left:830,top:578,width:260,height:5,borderRadius:5,background:T.blue,transform:`scaleX(${ramp(f,58,12)})`}}/>
 <div style={{position:'absolute',left:0,right:0,top:622,textAlign:'center',fontSize:52,color:T.muted,opacity:ramp(f,68,12)}}>{caption}</div>
 <div style={{position:'absolute',left:0,right:0,top:708,textAlign:'center',fontSize:52,color:T.blue,opacity:ramp(f,78,15)}}>Connect. Copy. Keep going.</div>
 <AbsoluteFill style={{pointerEvents:'none'}}>{Array.from({length:16},(_,i)=><div key={i} style={{position:'absolute',left:(i*439+137)%1920,top:(i*613+271)%1080-Math.min(f,100)*.25,width:3,height:3,borderRadius:5,background:T.lightBlue,opacity:.15*ramp(f,20,20)}}/>)}</AbsoluteFill>
 </Surface>;
};
export const SCENES=[Intro,Network,Pair,Approve,Copy,Paste,Phone,ImageScene,Files,Consent,Extras,Outro];
