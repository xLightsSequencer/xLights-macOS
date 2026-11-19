#pragma once

/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

namespace AppleCollab {

// The running app was signed with `key` set to true. Read from the main
// executable's own code signature, which works on iOS (where SecTask is not
// available) as well as macOS.
bool HasEntitlement(const char* key);

} // namespace AppleCollab
