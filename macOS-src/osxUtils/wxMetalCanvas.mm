#include <map>

#include <TargetConditionals.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>

#import <QuartzCore/QuartzCore.h>

#include <log4cpp/Category.hh>

#include "wxMetalCanvas.hpp"


#include "wx/frame.h"
#include "wx/log.h"
#include "wx/settings.h"
#include "wx/osx/private.h"

BEGIN_EVENT_TABLE(wxMetalCanvas, wxWindow)
END_EVENT_TABLE()

wxMetalCanvas::wxMetalCanvas(wxWindow *parent,
                             wxWindowID id,
                             const wxPoint& pos,
                             const wxSize& size,
                             long style,
                             const wxString& n,
                             bool only2d) : name(n.ToStdString())
{
    if (Create(parent, id, pos, size, wxFULL_REPAINT_ON_RESIZE | wxCLIP_CHILDREN | wxCLIP_SIBLINGS | style, name, only2d)) {

    }
}


@interface wxCustomMTKView : MTKView
{
}

@end

@implementation wxCustomMTKView

+ (void)initialize
{
    static BOOL initialized = NO;
    if (!initialized) {
        initialized = YES;
        wxOSXCocoaClassAddWXMethods( self );
    }
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL) acceptsFirstResponder
{
    return YES;
}

// for special keys
- (void)doCommandBySelector:(SEL)aSelector
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl)
        impl->doCommandBySelector(aSelector, self, _cmd);
}

@end

class PipelineInfo {
public:
    PipelineInfo() {
        state = nil;
    }
    ~PipelineInfo() {
        state = nil;
    }
    id <MTLRenderPipelineState> state;
};


static id<MTLDevice> MTL_DEVICE = nil;
static id<MTLCommandQueue> MTL_COMMAND_QUEUE = nil;
static id<MTLLibrary> MTL_DEFAULT_LIBRARY = nil;
static id<MTLDepthStencilState> MTL_DEPTH_STENCIL_STATE_LE = nil;
static id<MTLDepthStencilState> MTL_DEPTH_STENCIL_STATE_L = nil;
static int MTL_SAMPLE_COUNT = 1;

static std::map<std::string, PipelineInfo> PIPELINE_STATES_2D;
static std::map<std::string, PipelineInfo> BLENDED_PIPELINE_STATES_2D;
static std::map<std::string, PipelineInfo> PIPELINE_STATES_3D;
static std::map<std::string, PipelineInfo> BLENDED_PIPELINE_STATES_3D;
static std::atomic_int METAL_USE_COUNT(0);

wxMetalCanvas::~wxMetalCanvas() {
    METAL_USE_COUNT--;

    if (METAL_USE_COUNT == 0) {
        for (auto &a : PIPELINE_STATES_2D) {
            [a.second.state release];
            a.second.state = nil;
        }
        PIPELINE_STATES_2D.clear();
        for (auto &a : BLENDED_PIPELINE_STATES_2D) {
            [a.second.state release];
            a.second.state = nil;
        }
        BLENDED_PIPELINE_STATES_2D.clear();
        for (auto &a : PIPELINE_STATES_3D) {
            [a.second.state release];
            a.second.state = nil;
        }
        PIPELINE_STATES_3D.clear();
        for (auto &a : BLENDED_PIPELINE_STATES_3D) {
            [a.second.state release];
            a.second.state = nil;
        }
        BLENDED_PIPELINE_STATES_3D.clear();
        if (MTL_DEPTH_STENCIL_STATE_LE) {
            [MTL_DEPTH_STENCIL_STATE_LE release];
            MTL_DEPTH_STENCIL_STATE_LE = nil;
        }
        if (MTL_DEPTH_STENCIL_STATE_L) {
            [MTL_DEPTH_STENCIL_STATE_L release];
            MTL_DEPTH_STENCIL_STATE_L = nil;
        }
        if (MTL_COMMAND_QUEUE) {
            [MTL_COMMAND_QUEUE release];
            MTL_COMMAND_QUEUE = nil;
        }
        if (MTL_DEFAULT_LIBRARY) {
            [MTL_DEFAULT_LIBRARY release];
            MTL_DEFAULT_LIBRARY = nil;
        }
        if (MTL_DEVICE) {
            [MTL_DEVICE release];
            MTL_DEVICE = nil;
        }
    }
}
MTKView* wxMetalCanvas::getMTKView() const {
    return (MTKView*)this->GetHandle();
}

id<MTLDevice> wxMetalCanvas::getMTLDevice() {
    return MTL_DEVICE;
}
id<MTLLibrary> wxMetalCanvas::getMTLLibrary() {
    return MTL_DEFAULT_LIBRARY;
}
id<MTLDepthStencilState> wxMetalCanvas::getDepthStencilStateLE() {
    return MTL_DEPTH_STENCIL_STATE_LE;
}
id<MTLDepthStencilState> wxMetalCanvas::getDepthStencilStateL() {
    return MTL_DEPTH_STENCIL_STATE_L;
}
id<MTLCommandQueue> wxMetalCanvas::getMTLCommandQueue() {
    return MTL_COMMAND_QUEUE;
}

int wxMetalCanvas::getMSAASampleCount() {
    return MTL_SAMPLE_COUNT;
}


bool wxMetalCanvas::Create(wxWindow *parent,
                           wxWindowID id,
                           const wxPoint& pos,
                           const wxSize& size,
                           long style,
                           const wxString& name,
                           bool only2d) {

    is3d = !only2d;
    usesMsaa = is3d;
    DontCreatePeer();

    if (!wxWindow::Create(parent, id, pos, size, style, name)) {
        return false;
    }

    if (METAL_USE_COUNT == 0) {
        MTL_DEVICE = MTLCreateSystemDefaultDevice();
        MTL_COMMAND_QUEUE = [MTL_DEVICE newCommandQueue];
        [MTL_COMMAND_QUEUE setLabel:@"xLightsMetalCommandQueue"];
        MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
        depthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
        depthDescriptor.depthWriteEnabled = YES;
        MTL_DEPTH_STENCIL_STATE_LE = [MTL_DEVICE newDepthStencilStateWithDescriptor:depthDescriptor];
        [depthDescriptor release];
        
        depthDescriptor = [MTLDepthStencilDescriptor new];
        depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
        depthDescriptor.depthWriteEnabled = YES;
        MTL_DEPTH_STENCIL_STATE_L = [MTL_DEVICE newDepthStencilStateWithDescriptor:depthDescriptor];
        [depthDescriptor release];
        
        if ([MTL_DEVICE supportsTextureSampleCount:2]) {
            //don't need super nice so attempt msaa 2 first
            MTL_SAMPLE_COUNT = 2;
        } else if ([MTL_DEVICE supportsTextureSampleCount:4]) {
            MTL_SAMPLE_COUNT = 4;
        } else if ([MTL_DEVICE supportsTextureSampleCount:8]) {
            MTL_SAMPLE_COUNT = 8;
        }
    }
    METAL_USE_COUNT++;

    NSRect r = wxOSXGetFrameForControl(this, pos , size);
    wxCustomMTKView* v = [[wxCustomMTKView alloc] initWithFrame:r device:MTL_DEVICE];
    [v retain];
    [v setPaused:true];
    [v setEnableSetNeedsDisplay:true];
    [v setColorPixelFormat:MTLPixelFormatBGRA8Unorm ];
    [v setClearColor:MTLClearColorMake(0, 0, 0, 1)];
    
    NSString *vname = [NSString stringWithUTF8String:name.c_str()];
    [[v layer] setName:vname];
    
    if (!only2d) {
        [v setSampleCount:MTL_SAMPLE_COUNT];
        [v setDepthStencilPixelFormat:MTLPixelFormatDepth32Float];
    }

    wxWidgetCocoaImpl* c = new wxWidgetCocoaImpl( this, v, wxWidgetImpl::Widget_UserKeyEvents | wxWidgetImpl::Widget_UserMouseEvents );
    SetPeer(c);
    MacPostControlCreate(pos, size) ;
    return true;
}

id<MTLRenderPipelineState> wxMetalCanvas::getPipelineState(const std::string &n, const char *vShader, const char *fShader,
                                                           bool blending) {
    std::string name = n;
    bool is3d = RequiresDepthBuffer();
    bool msaa = usesMsaa || is3d;
    if (!is3d && msaa) {
        name += "MSAA";
    }
    auto &a = is3d ? (blending ? BLENDED_PIPELINE_STATES_3D[name] : PIPELINE_STATES_3D[name])
                : (blending ? BLENDED_PIPELINE_STATES_2D[name] : PIPELINE_STATES_2D[name]);
    if (a.state == nil) {
        static log4cpp::Category& logger_base = log4cpp::Category::getInstance(std::string("log_base"));
        if (MTL_DEFAULT_LIBRARY == nil) {
            MTL_DEFAULT_LIBRARY = [MTL_DEVICE newDefaultLibrary];
        }
        @autoreleasepool {
            MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
            [desc colorAttachments][0].pixelFormat = [getMTKView() colorPixelFormat];
            if (blending) {
                [desc colorAttachments][0].blendingEnabled = true;
                [desc colorAttachments][0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                [desc colorAttachments][0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                [desc colorAttachments][0].sourceAlphaBlendFactor = MTLBlendFactorOne;
                [desc colorAttachments][0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            }
            if (is3d) {
                [desc setDepthAttachmentPixelFormat:MTLPixelFormatDepth32Float];
            }
            if (msaa) {
                [desc setSampleCount:MTL_SAMPLE_COUNT];
            }
            NSString *nsVName= [[[NSString alloc] initWithUTF8String:vShader] autorelease];
            NSString *nsFName= [[[NSString alloc] initWithUTF8String:fShader] autorelease];

            desc.vertexFunction = [[MTL_DEFAULT_LIBRARY newFunctionWithName:nsVName] autorelease];
            desc.fragmentFunction = [[MTL_DEFAULT_LIBRARY newFunctionWithName:nsFName] autorelease];
            
            MTLVertexDescriptor *mtlVertexDescriptor = nil;
            if (n == "meshSolidProgram" || n == "meshTextureProgram" || n == "meshWireframeProgram") {
                //need a complex vertex descriptor
                mtlVertexDescriptor = [[MTLVertexDescriptor alloc] init];

                // Positions.
                mtlVertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
                mtlVertexDescriptor.attributes[0].offset = 0;
                mtlVertexDescriptor.attributes[0].bufferIndex = 0;
                // Normals.
                mtlVertexDescriptor.attributes[1].format = MTLVertexFormatFloat3;
                mtlVertexDescriptor.attributes[1].offset = 12;
                mtlVertexDescriptor.attributes[1].bufferIndex = 0;
                // Texture coordinates.
                mtlVertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;
                mtlVertexDescriptor.attributes[2].offset = 24;
                mtlVertexDescriptor.attributes[2].bufferIndex = 0;

                // Single interleaved buffer.
                mtlVertexDescriptor.layouts[0].stride = 32;
                mtlVertexDescriptor.layouts[0].stepRate = 1;
                mtlVertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
                desc.vertexDescriptor = mtlVertexDescriptor;
            } else if (n == "indexedColorProgram" || n == "indexedColorPointsProgram") {
                mtlVertexDescriptor = [[MTLVertexDescriptor alloc] init];

                // Positions X
                mtlVertexDescriptor.attributes[0].format = MTLVertexFormatFloat;
                mtlVertexDescriptor.attributes[0].offset = 0;
                mtlVertexDescriptor.attributes[0].bufferIndex = 0;
                // Positions Y
                mtlVertexDescriptor.attributes[1].format = MTLVertexFormatFloat;
                mtlVertexDescriptor.attributes[1].offset = 4;
                mtlVertexDescriptor.attributes[1].bufferIndex = 0;
                // Positions Z
                mtlVertexDescriptor.attributes[2].format = MTLVertexFormatFloat;
                mtlVertexDescriptor.attributes[2].offset = 8;
                mtlVertexDescriptor.attributes[2].bufferIndex = 0;
                // Color index
                mtlVertexDescriptor.attributes[3].format = MTLVertexFormatUInt;
                mtlVertexDescriptor.attributes[3].offset = 12;
                mtlVertexDescriptor.attributes[3].bufferIndex = 0;

                // Single interleaved buffer.
                mtlVertexDescriptor.layouts[0].stride = 16;
                mtlVertexDescriptor.layouts[0].stepRate = 1;
                mtlVertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
                desc.vertexDescriptor = mtlVertexDescriptor;
            }

            NSError *nserror;
            a.state = [[MTL_DEVICE newRenderPipelineStateWithDescriptor:desc error:&nserror] retain];
            [desc release];
            if (mtlVertexDescriptor != nil) {
                [mtlVertexDescriptor release];
            }
            if (nserror) {
                NSString *err = [NSString stringWithFormat:@"%@", nserror];
                logger_base.info("Could not create render pipeline for %s:  %s", name.c_str(), [err UTF8String]);
                [nserror release];
            }
        }
    }
    return a.state;
}

 
void wxMetalCanvas::addToSyncPoint(id<MTLCommandBuffer> &buffer, id<CAMetalDrawable> &drawable) {
    if (!isUsingPresentTime) {
        [buffer presentDrawable:drawable];
        [buffer commit];
    } else {
        [buffer presentDrawable:drawable atTime:nextPresentTime];
        [buffer commit];
        isUsingPresentTime = false;
    }
}

int wxMetalCanvas::getScreenIndex() const {
    NSScreen *scr = [getMTKView() window].screen;
    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSUInteger i = 0; i < screens.count; i++) {
        if (screens[i] == scr) {
            return i;
        }
    }
    return 0;
}
bool wxMetalCanvas::startFrameForTime(double ts) {
    if (ts > nextPresentTime) {
        nextPresentTime = ts;
        isUsingPresentTime = true;
        return true;
    }
    return false;
}

