#include <wx/window.h>


#ifdef __OBJC__
#import <foundation/foundation.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#else
class MTKView;
#endif


class wxMetalCanvas : public wxWindow {
public:
    wxMetalCanvas(wxWindow *parent,
                  wxWindowID id = wxID_ANY,
                  const wxPoint& pos = wxDefaultPosition,
                  const wxSize& size = wxDefaultSize,
                  long style = 0,
                  const wxString& name = "");
    wxMetalCanvas(wxWindow *parent, const wxString& name) : wxMetalCanvas(parent, wxID_ANY, wxDefaultPosition, wxDefaultSize, 0, name) {}

    virtual ~wxMetalCanvas();



#ifdef __OBJC__
    //methods only available from objective-c.  Cannot be virtual as they cannot be in the virtual function table
    static id<MTLDevice> getMTLDevice();
    static id<MTLLibrary> getMTLLibrary();
    static id<MTLCommandQueue> getMTLCommandQueue();

    MTKView* getMTKView() const;
    id<MTLRenderPipelineState> getPipelineState(const std::string &name, const char *vShader, const char *fShader, bool blending = false);
#endif


protected:
    DECLARE_EVENT_TABLE()


    bool Create(wxWindow *parent,
                wxWindowID id = wxID_ANY,
                const wxPoint& pos = wxDefaultPosition,
                const wxSize& size = wxDefaultSize,
                long style = 0,
                const wxString& name = "");

};
