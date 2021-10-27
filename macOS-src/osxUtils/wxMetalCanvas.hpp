#include <wx/window.h>

#include "CPPMetal/CPPMetal.hpp"

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


    MTK::View *getMTKView() const { return view; };
    MTL::Device *getMTLDevice() const { return device; };
    MTL::Library *getMTLLibrary() const { return library; };
    MTL::CommandQueue *getMTLCommandQueue() const { return commandQueue; };


    MTL::RenderPipelineState getPipelineState(const std::string &name, const char *vShader, const char *fShader);

protected:
    DECLARE_EVENT_TABLE()


    bool Create(wxWindow *parent,
                wxWindowID id = wxID_ANY,
                const wxPoint& pos = wxDefaultPosition,
                const wxSize& size = wxDefaultSize,
                long style = 0,
                const wxString& name = "");



    MTK::View *view;

    static MTL::Device *device;
    static MTL::CommandQueue *commandQueue;
    static MTL::Library *library;

};
