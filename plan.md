
# Figure out how to render cef frames directly to vkimage by gpu
try and see if its durable this time to get cef to render directly to the vkimage
else worst case we must resort to cpu blit if all fails...

* https://cef-builds.spotifycdn.com/index.html#macosx64
for src..
for now just focus on macOS x86-64 until its working as expected, then we can expand platform support..
ios / android should be ignored... since they need to rely on something else... 
so cef is just for desktops..


# CEF Protocols
define some protocols and extensions to them that helps datamodel part interface, abit easier with
some of the cef api..
soo after we can define some @Observable datamodels based on those protocols
abit like how NucleantThorVG was done with Scene, Shape and so on...
soo the CEFView can be generic for DataModel input.. and user can decide how they work...


# CEFView
make a CEFView and i guess will function abit like the Shaders where it uses BuiltinView
and is Generic to DataModel protocols part.. 



