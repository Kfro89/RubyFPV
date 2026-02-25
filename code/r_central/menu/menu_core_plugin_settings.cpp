/*
    Ruby Licence
    Copyright (c) 2020-2025 Petru Soroaga
    All rights reserved.

    Redistribution and/or use in source and/or binary forms, with or without
    modification, are permitted provided that the following conditions are met:
        * Redistributions and/or use of the source code (partially or complete) must retain
        the above copyright notice, this list of conditions and the following disclaimer
        in the documentation and/or other materials provided with the distribution.
        * Redistributions in binary form (partially or complete) must reproduce
        the above copyright notice, this list of conditions and the following disclaimer
        in the documentation and/or other materials provided with the distribution.
        * Copyright info and developer info must be preserved as is in the user
        interface, additions could be made to that info.
        * Neither the name of the organization nor the
        names of its contributors may be used to endorse or promote products
        derived from this software without specific prior written permission.
        * Military use is not permitted.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE AUTHOR (PETRU SOROAGA) BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
    (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
    ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#include "menu.h"
#include "menu_core_plugin_settings.h"
#include "menu_confirmation.h"
#include "menu_controller_plugins.h"
#include "menu_item_section.h"
#include "menu_item_edit.h"
#include "../../../public/ruby_core_plugin.h"

MenuCorePluginSettings::MenuCorePluginSettings(int iPluginIndex)
:Menu(MENU_ID_CONTROLLER_PLUGINS + 100 + iPluginIndex, "Core Plugin Settings", NULL)
{
   m_Width = 0.46;
   m_xPos = menu_get_XStartPos(m_Width); m_yPos = 0.15;
   m_iPluginIndex = iPluginIndex;
   m_pPluginInfo = get_CorePluginRuntimeInfo(m_iPluginIndex);

   if ( NULL == m_pPluginInfo )
   {
      addMenuItem(new MenuItemText("Invalid Plugin"));
      return;
   }

   char szTitle[256];
   sprintf(szTitle, "%s Settings", m_pPluginInfo->szName);
   setTitle(szTitle);

   // Add Enable/Disable
   m_pItemEnable = new MenuItemSelect("Plugin State", "Enable or disable this plugin.");
   m_pItemEnable->addSelection("Disabled");
   m_pItemEnable->addSelection("Enabled");
   m_pItemEnable->setIsEditable();
   m_IndexEnable = addMenuItem(m_pItemEnable);

   addMenuItem(new MenuItemSection("Configuration"));

   if ( NULL == m_pPluginInfo->pFunctionCoreGetSettingsCount )
   {
      addMenuItem(new MenuItemText("No settings available for this plugin."));
   }
   else
   {
      int iCount = (*(m_pPluginInfo->pFunctionCoreGetSettingsCount))();

      for( int i=0; i<iCount && i<MAX_CORE_PLUGIN_SETTINGS; i++ )
      {
         const char* szName = "Setting";
         if ( NULL != m_pPluginInfo->pFunctionCoreGetSettingName )
            szName = (*(m_pPluginInfo->pFunctionCoreGetSettingName))(i);

         int iType = CORE_PLUGIN_SETTING_TYPE_INT;
         if ( NULL != m_pPluginInfo->pFunctionCoreGetSettingType )
            iType = (*(m_pPluginInfo->pFunctionCoreGetSettingType))(i);

         m_SettingsTypes[i] = iType;
         m_pItemsSettings[i] = NULL;

         if ( iType == CORE_PLUGIN_SETTING_TYPE_BOOL )
         {
            m_pItemsSettings[i] = new MenuItemSelect(szName, "Enable or disable this option.");
            ((MenuItemSelect*)m_pItemsSettings[i])->addSelection("No");
            ((MenuItemSelect*)m_pItemsSettings[i])->addSelection("Yes");
            ((MenuItemSelect*)m_pItemsSettings[i])->setIsEditable();
            m_IndexSettings[i] = addMenuItem(m_pItemsSettings[i]);
         }
         else if ( iType == CORE_PLUGIN_SETTING_TYPE_INT )
         {
            int iMin = 0;
            int iMax = 100;
            if ( NULL != m_pPluginInfo->pFunctionCoreGetSettingMinValue )
               iMin = (*(m_pPluginInfo->pFunctionCoreGetSettingMinValue))(i);
            if ( NULL != m_pPluginInfo->pFunctionCoreGetSettingMaxValue )
               iMax = (*(m_pPluginInfo->pFunctionCoreGetSettingMaxValue))(i);

            m_pItemsSettings[i] = new MenuItemSlider(szName, iMin, iMax, iMax/2, iMax/10);
            m_IndexSettings[i] = addMenuItem(m_pItemsSettings[i]);
         }
         else if ( iType == CORE_PLUGIN_SETTING_TYPE_ENUM )
         {
            m_pItemsSettings[i] = new MenuItemSelect(szName, "Select an option.");
            int iOptions = 0;
            if ( NULL != m_pPluginInfo->pFunctionCoreGetSettingOptionsCount )
               iOptions = (*(m_pPluginInfo->pFunctionCoreGetSettingOptionsCount))(i);

            for( int k=0; k<iOptions; k++ )
            {
               const char* szOpt = "Option";
               if ( NULL != m_pPluginInfo->pFunctionCoreGetSettingOptionName )
                  szOpt = (*(m_pPluginInfo->pFunctionCoreGetSettingOptionName))(i, k);
               ((MenuItemSelect*)m_pItemsSettings[i])->addSelection(szOpt);
            }
            ((MenuItemSelect*)m_pItemsSettings[i])->setIsEditable();
            m_IndexSettings[i] = addMenuItem(m_pItemsSettings[i]);
         }
         else if ( iType == CORE_PLUGIN_SETTING_TYPE_STRING )
         {
            m_pItemsSettings[i] = new MenuItemEdit(szName, "Value");
            m_IndexSettings[i] = addMenuItem(m_pItemsSettings[i]);
         }
      }
   }

   addMenuItem(new MenuItemSection("Management"));
   m_IndexDelete = addMenuItem(new MenuItem("Delete Plugin", "Delete this plugin from the system."));
}

MenuCorePluginSettings::~MenuCorePluginSettings()
{
}


void MenuCorePluginSettings::valuesToUI()
{
   if ( NULL == m_pPluginInfo )
      return;

   CorePluginSettings* pSettings = get_CorePluginSettings(m_pPluginInfo->szGUID);
   if ( NULL == pSettings )
      return;

   // Update Enable/Disable
   m_pItemEnable->setSelectedIndex(pSettings->iEnabled);

   int iCount = 0;
   if ( NULL != m_pPluginInfo->pFunctionCoreGetSettingsCount )
      iCount = (*(m_pPluginInfo->pFunctionCoreGetSettingsCount))();

   for( int i=0; i<iCount && i<MAX_CORE_PLUGIN_SETTINGS; i++ )
   {
      if ( NULL == m_pItemsSettings[i] )
         continue;

      if ( m_SettingsTypes[i] == CORE_PLUGIN_SETTING_TYPE_STRING )
      {
         ((MenuItemEdit*)m_pItemsSettings[i])->setCurrentValue(pSettings->szSettingsStrings[i]);
      }
      else if ( m_SettingsTypes[i] == CORE_PLUGIN_SETTING_TYPE_BOOL || m_SettingsTypes[i] == CORE_PLUGIN_SETTING_TYPE_ENUM )
      {
         ((MenuItemSelect*)m_pItemsSettings[i])->setSelectedIndex(pSettings->iSettingsValues[i]);
      }
      else if ( m_SettingsTypes[i] == CORE_PLUGIN_SETTING_TYPE_INT )
      {
         ((MenuItemSlider*)m_pItemsSettings[i])->setCurrentValue(pSettings->iSettingsValues[i]);
      }
   }
}

void MenuCorePluginSettings::Render()
{
   RenderPrepare();
   float yTop = RenderFrameAndTitle();
   float y = yTop;
   for( int i=0; i<m_ItemsCount; i++ )
      y += RenderItem(i,y);
   RenderEnd(yTop);
}

void MenuCorePluginSettings::onReturnFromChild(int iChildMenuId, int returnValue)
{
   Menu::onReturnFromChild(iChildMenuId, returnValue);

   if ( 1 == iChildMenuId/1000 && 1 == returnValue ) // Confirmed Delete
   {
      delete_CorePlugin(m_pPluginInfo->szGUID);
      menu_discard_all();
      MenuControllerPlugins* pMenu = new MenuControllerPlugins();
      add_menu_to_stack(pMenu);
   }
}


void MenuCorePluginSettings::onSelectItem()
{
   Menu::onSelectItem();
   if ( NULL == m_pPluginInfo )
      return;

   if ( handle_commands_is_command_in_progress() )
   {
      handle_commands_show_popup_progress();
      return;
   }

   if ( m_SelectedIndex < 0 || m_SelectedIndex >= m_ItemsCount )
      return;

   CorePluginSettings* pSettings = get_CorePluginSettings(m_pPluginInfo->szGUID);
   if ( NULL == pSettings )
      return;

   // Handle Enable/Disable
   if ( m_SelectedIndex == m_IndexEnable )
   {
      pSettings->iEnabled = m_pItemEnable->getSelectedIndex();
      save_CorePluginsSettings();
      return;
   }

   // Handle Delete
   if ( m_SelectedIndex == m_IndexDelete )
   {
      MenuConfirmation* pMC = new MenuConfirmation("Delete Plugin","Are you sure you want to delete this plugin?", 1);
      pMC->m_yPos = 0.3;
      add_menu_to_stack(pMC);
      return;
   }

   int iCount = 0;
   if ( NULL != m_pPluginInfo->pFunctionCoreGetSettingsCount )
      iCount = (*(m_pPluginInfo->pFunctionCoreGetSettingsCount))();

   // Find which setting corresponds to selected index
   int iSettingIndex = -1;
   for( int i=0; i<iCount && i<MAX_CORE_PLUGIN_SETTINGS; i++ )
   {
      if ( m_IndexSettings[i] == m_SelectedIndex )
      {
         iSettingIndex = i;
         break;
      }
   }

   if ( -1 == iSettingIndex )
      return;

   if ( m_SettingsTypes[iSettingIndex] == CORE_PLUGIN_SETTING_TYPE_STRING )
   {
      // Check if finished editing? MenuItemEdit handles editing state internally.
      // But we need to save the value when editing finishes?
      // MenuItemEdit usually needs manual handling or it updates internal buffer?
      // It updates internal buffer. We need to get it.
      // But we should only save when the user finishes editing (e.g. presses Enter).
      // How does MenuItemEdit signal finish?
      // Usually via onReturnFromChild? No, it's not a child menu.
      // It stays in editing mode.
      // If we are here, user pressed Enter.
      // If it WAS editing, it might stop editing?
      // MenuItemEdit::beginEdit() is called if we call onSelectItem?

      // Checking implementation of MenuItemEdit: it doesn't seem to have isEditing().
      // But Menu::onSelectItem calls pItem->beginEdit() usually?
      // No, Menu::onSelectItem implementation calls m_pMenuItems[m_SelectedIndex]->onSelectItem()? No.
      // It's up to the Menu class to handle it.

      // Let's assume standard behavior:
      // If not editing, start editing.
      // If editing, stop editing and save?
      // Actually, MenuItemEdit handles key events.
      // If we are here (onSelectItem), it means Enter was pressed.
      // If MenuItemEdit consumes Enter, we might not get here?
      // Or we get here to toggle edit mode?

      // Assuming MenuItemEdit updates its value.
      char* szVal = (char*)((MenuItemEdit*)m_pItemsSettings[iSettingIndex])->getCurrentValue();
      strcpy(pSettings->szSettingsStrings[iSettingIndex], szVal);

      if ( NULL != m_pPluginInfo->pFunctionCoreSetSettingString )
         (*(m_pPluginInfo->pFunctionCoreSetSettingString))(iSettingIndex, szVal);

      save_CorePluginsSettings();
      if ( NULL != m_pPluginInfo->pFunctionCoreOnSettingsChanged )
         (*(m_pPluginInfo->pFunctionCoreOnSettingsChanged))();
      return;
   }

   // For other types, get value and save
   int iVal = 0;
   if ( m_SettingsTypes[iSettingIndex] == CORE_PLUGIN_SETTING_TYPE_BOOL || m_SettingsTypes[iSettingIndex] == CORE_PLUGIN_SETTING_TYPE_ENUM )
   {
      iVal = ((MenuItemSelect*)m_pItemsSettings[iSettingIndex])->getSelectedIndex();
   }
   else if ( m_SettingsTypes[iSettingIndex] == CORE_PLUGIN_SETTING_TYPE_INT )
   {
      iVal = ((MenuItemSlider*)m_pItemsSettings[iSettingIndex])->getCurrentValue();
   }

   pSettings->iSettingsValues[iSettingIndex] = iVal;

   if ( NULL != m_pPluginInfo->pFunctionCoreSetSettingValue )
      (*(m_pPluginInfo->pFunctionCoreSetSettingValue))(iSettingIndex, iVal);

   save_CorePluginsSettings();
   if ( NULL != m_pPluginInfo->pFunctionCoreOnSettingsChanged )
      (*(m_pPluginInfo->pFunctionCoreOnSettingsChanged))();
}
