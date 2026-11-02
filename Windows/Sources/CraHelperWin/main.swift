import CraCEFWin
import ucrt

// Entry point for every Chromium subprocess (renderer, GPU, utility). CEF tells it what to be
// through the command line. Swift rather than C++ so SwiftPM links it like the app: a C++-only
// executable gets the Swift runtime's start-up object without the runtime.
exit(cra_cef_execute_process())
