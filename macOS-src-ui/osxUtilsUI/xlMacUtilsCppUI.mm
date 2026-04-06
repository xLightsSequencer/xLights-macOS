//
//  xlMacUtilsCppUI.cpp
//  xLights-macOSLib
//
//  UI-specific macOS utility implementations.  Depends on wxWidgets.
//

#include <set>

#include <wx/dir.h>
#include <wx/filename.h>
#include <wx/string.h>
#include <wx/colour.h>
#include <wx/button.h>
#include <wx/window.h>

#include "ExternalHooksMacOSUI.h"
#include "xLights_macOSLib_UI-Swift.h"

bool FileExists(const wxFileName &fn, bool waitForDownload) {
    return FileExists(fn.GetFullPath().ToStdString(), waitForDownload);
}
bool FileExists(const wxString &s, bool waitForDownload) {
    return FileExists(s.ToStdString(), waitForDownload);
}

wxString GetOSFormattedClipboardData() {
    std::string s = xLights_macOSLib_UI::getOSFormattedClipboardData();
    return wxString(s);
}

void GetAllFilesInDir(const wxString &dir, wxArrayString &files, const wxString &filespec, int flags) {
    if (flags == -1) {
        flags = wxDIR_FILES;
    }
    flags |= wxDIR_HIDDEN;
    static std::string iCloudExt = ".icloud";
    wxArrayString f2;
    std::set<wxString> allFiles;
    wxDir::GetAllFiles(dir, &f2, filespec, flags);
    if (filespec != "") {
        wxDir::GetAllFiles(dir, &f2, filespec + iCloudExt, flags);
    }
    for (auto &a : f2) {
        // this will remove duplicates that match both ext
        allFiles.insert(a);
    }
    for (auto &f : allFiles) {
        if (f.EndsWith(iCloudExt)) {
            int pos = f.find_last_of('/');
            wxString n = f.substr(0, pos + 1);
            n += f.substr(pos + 2, f.size() - 9 - pos);
            files.push_back(n);
        } else {
            files.push_back(f);
        }
    }
}
