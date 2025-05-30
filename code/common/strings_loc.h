#pragma once

#ifdef __cplusplus
extern "C" {
#endif 

void initLocalizationData();
int getLanguagesCount();
const char* getLanguageName(int iIndex);
void setActiveLanguage(int iLanguage);

const char* L(const char* szString);

#ifdef __cplusplus
}  
#endif
