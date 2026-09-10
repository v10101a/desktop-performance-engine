// Syphon's umbrella header leaves out SyphonSubclassing.h, and that category is where
// -[SyphonServerBase copySurfaceForWidth:height:options:] and -publish live: the two calls
// that let a plain SyphonServerBase publish an IOSurface we render into with Metal, on a
// framework build that has no SyphonMetalServer of its own. Importing both here (rather
// than editing the framework, which would break its signature) is what makes them
// reachable from Swift.
#import <Syphon/Syphon.h>
#import <Syphon/SyphonSubclassing.h>
