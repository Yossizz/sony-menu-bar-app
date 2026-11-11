#pragma once
#include <mdr-c/Base.h>
#include <mdr-c/Connection.h>
#include <mdr-c/Headphones.h>
#include <mdr-bt/ConnectionMacOS.h>

// Macros built from expressions don't import into Swift; re-export them as constants.
static const uint32_t XM_ABI_VERSION = MDR_ABI_VERSION;
static const MDRHeadphonesInitFlags XM_INIT_DEFAULT = MDR_HEADPHONES_INIT_DEFAULT;
static const MDRHeadphonesSyncFlags XM_SYNC_DEFAULT = MDR_HEADPHONES_SYNC_DEFAULT;
