#pragma once
#include "menu_objects.h"
#include "menu_item_select.h"
#include "menu_item_slider.h"
#include "menu_item_range.h"
#include "menu_item_text.h"
#include "../../base/core_plugins_settings.h"

class MenuCorePluginSettings: public Menu
{
   public:
      MenuCorePluginSettings(int iPluginIndex);
      virtual ~MenuCorePluginSettings();
      virtual void valuesToUI();
      virtual void Render();
      virtual void onReturnFromChild(int iChildMenuId, int returnValue);
      virtual void onSelectItem();

   private:
      int m_iPluginIndex;
      CorePluginRuntimeInfo* m_pPluginInfo;

      int m_IndexSettings[MAX_CORE_PLUGIN_SETTINGS];
      MenuItem* m_pItemsSettings[MAX_CORE_PLUGIN_SETTINGS];
      int m_SettingsTypes[MAX_CORE_PLUGIN_SETTINGS];

      int m_IndexEnable;
      MenuItemSelect* m_pItemEnable;
      int m_IndexDelete;
};
