export const TOTAL=1800;
// Measured on two isolated SFX probes: AAC mux delay 1.27–1.28 frames.
// Advance one whole frame; residual 0.27–0.28 frames, below the 3-frame limit.
export const AUDIO_ADVANCE=1;
const beats=[
 ['intro','Your clipboard.\nAcross your devices.','A shared clipboard for nearby devices.','Meet Hopboard. A shared clipboard for your nearby devices.'],
 ['network','Copy here. Paste there.','Same Wi-Fi. No account, cloud, or internet.','Copy here. Paste there. Same Wi-Fi. No account, cloud, or internet required.'],
 ['pair','Pair once.','Join the host with its six-digit code.','Start session. Add device. Select the host. Enter its six-digit code.'],
 ['approve',"You’re in control.",'Approve devices. Choose automatic sharing.','Approve the device. Enable automatic sharing when you\'re ready.'],
 ['copy','Copy on your laptop.','Copy a link, note, or idea.','Copy a link or note on your laptop.'],
 ['paste','Keep going on your PC.','Paste on another PC. Keep going.','It crosses your local network. Paste it on your other PC.'],
 ['phone','Your phone joins in.','Keep Hopboard open on Android.','On Android, keep Hopboard open. Use Paste and Send, or Copy.'],
 ['image','Beyond text.','Images between PCs. In development.','Beyond text: Windows development builds also share images.'],
 ['files','Files. Folders. ZIPs.','Download. Verify. Ready to paste.','Send files, folders, or ZIPs. Verified before they are ready to paste.'],
 ['consent','Choose what shares.','Images and files need separate permission.','You choose what shares. Images and files each need separate permission.'],
 ['extras','The useful little things.','Tray controls. Trusted devices. Themes.','Pause from the tray. Reconnect trusted devices. Follow your system theme.'],
 ['outro','Hopboard','Your devices. One local clipboard.','Hopboard. Your devices. One local clipboard.'],
];
export const SHOTS=beats.map(([id,title,caption,voice],i)=>({id,title,caption,voice,index:i,from:i*150,duration:150,narrativeGoal:caption,visual:id,motion:id==='outro'?'outro-group-photo-launch':'custom native-workflow illustration',audio:`audio/voice-${String(i).padStart(2,'0')}.mp3`,assetRefs:['textures/clipboard.png','branding/icon.png']}));
export const SFX=[
 {from:SHOTS[0].from+15,src:'audio/sweep.wav',duration:18,volume:.22},
 {from:SHOTS[2].from+65,src:'audio/click.wav',duration:3,volume:.5},
 {from:SHOTS[3].from+45,src:'audio/click.wav',duration:3,volume:.5},
 {from:SHOTS[3].from+88,src:'audio/click.wav',duration:3,volume:.4},
 {from:SHOTS[4].from+70,src:'audio/click.wav',duration:3,volume:.55},
 {from:SHOTS[5].from+30,src:'audio/sweep.wav',duration:18,volume:.27},
 {from:SHOTS[5].from+90,src:'audio/click.wav',duration:3,volume:.55},
 {from:SHOTS[7].from+20,src:'audio/sweep.wav',duration:18,volume:.22},
 {from:SHOTS[8].from+45,src:'audio/click.wav',duration:3,volume:.4},
 {from:SHOTS[11].from,src:'audio/rise.wav',duration:42,volume:.3},
 {from:SHOTS[11].from+42,src:'audio/accent.wav',duration:24,volume:.42},
 {from:SHOTS[11].from+58,src:'audio/sweep.wav',duration:18,volume:.14},
];
