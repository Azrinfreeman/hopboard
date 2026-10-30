import React from 'react';
import {AbsoluteFill,Audio,Sequence,staticFile} from 'remotion';
import {SCENES} from './scenes';
import {SHOTS,SFX,AUDIO_ADVANCE} from './timeline';
export const Music=()=> <Audio
 src={staticFile('audio/hopboard-original-score.wav')}
 volume={.24}
/>;
export const Main:React.FC<{bgm?:boolean;voice?:boolean}>=({bgm=true,voice=true})=>(
 <AbsoluteFill>
  {SHOTS.map((s,i)=>{
   const Scene=SCENES[i];
   return (
    <Sequence key={s.id} name={s.title} from={s.from} durationInFrames={s.duration}>
     <Scene title={s.title} caption={s.caption} duration={s.duration}/>
    </Sequence>
   );
  })}
  {voice&&SHOTS.map(s=>(
   <Sequence key={s.id} name={`Narration: ${s.id}`} from={s.from+8} durationInFrames={s.duration-8}>
    <Audio src={staticFile(s.audio)} volume={.92}/>
   </Sequence>
  ))}
  {SFX.map((s,i)=>(
   <Sequence key={i} name={`SFX ${i}`} from={Math.max(0,s.from-AUDIO_ADVANCE)} durationInFrames={s.duration}>
    <Audio src={staticFile(s.src)} volume={s.volume}/>
   </Sequence>
  ))}
  {bgm&&<Music/>}
 </AbsoluteFill>
);
