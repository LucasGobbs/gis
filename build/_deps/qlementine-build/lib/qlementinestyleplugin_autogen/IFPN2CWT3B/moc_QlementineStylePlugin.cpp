/****************************************************************************
** Meta object code from reading C++ file 'QlementineStylePlugin.hpp'
**
** Created by: The Qt Meta Object Compiler version 69 (Qt 6.12.0)
**
** WARNING! All changes made in this file will be lost!
*****************************************************************************/

#include "../../../../qlementine-src/lib/src/style/QlementineStylePlugin.hpp"
#include <QtCore/qmetatype.h>
#include <QtCore/qplugin.h>

#include <QtCore/qtmochelpers.h>

#include <memory>


#include <QtCore/qxptype_traits.h>
#if !defined(Q_MOC_OUTPUT_REVISION)
#error "The header file 'QlementineStylePlugin.hpp' doesn't include <QObject>."
#elif Q_MOC_OUTPUT_REVISION != 69
#error "This file was generated using the moc from 6.12.0. It"
#error "cannot be used with the include files from this version of Qt."
#error "(The moc has changed too much.)"
#endif

#ifndef Q_CONSTINIT
#define Q_CONSTINIT
#endif

QT_WARNING_PUSH
QT_WARNING_DISABLE_DEPRECATED
QT_WARNING_DISABLE_GCC("-Wuseless-cast")
namespace {
struct qt_meta_tag_ZN6oclero10qlementine21QlementineStylePluginE_t {};
} // unnamed namespace

template <> constexpr inline auto oclero::qlementine::QlementineStylePlugin::qt_create_metaobjectdata<qt_meta_tag_ZN6oclero10qlementine21QlementineStylePluginE_t>()
{
    namespace QMC = QtMocConstants;
    QtMocHelpers::StringRefStorage qt_stringData {
        "oclero::qlementine::QlementineStylePlugin"
    };

    QtMocHelpers::UintData qt_methods {
    };
    QtMocHelpers::UintData qt_properties {
    };
    QtMocHelpers::UintData qt_enums {
    };
    return QtMocHelpers::metaObjectData<QlementineStylePlugin, qt_meta_tag_ZN6oclero10qlementine21QlementineStylePluginE_t>(QMC::MetaObjectFlag{}, qt_stringData,
            qt_methods, qt_properties, qt_enums);
}
Q_CONSTINIT const QMetaObject oclero::qlementine::QlementineStylePlugin::staticMetaObject = { {
    QMetaObject::SuperData::link<QStylePlugin::staticMetaObject>(),
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN6oclero10qlementine21QlementineStylePluginE_t>.stringdata,
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN6oclero10qlementine21QlementineStylePluginE_t>.data,
    qt_static_metacall,
    nullptr,
    qt_staticMetaObjectRelocatingContent<qt_meta_tag_ZN6oclero10qlementine21QlementineStylePluginE_t>.metaTypes,
    nullptr
} };

void oclero::qlementine::QlementineStylePlugin::qt_static_metacall(QObject *_o, QMetaObject::Call _c, int _id, void **_a)
{
    auto *_t = static_cast<QlementineStylePlugin *>(_o);
    (void)_t;
    (void)_c;
    (void)_id;
    (void)_a;
}

const QMetaObject *oclero::qlementine::QlementineStylePlugin::metaObject() const
{
    return QObject::d_ptr->metaObject ? QObject::d_ptr->dynamicMetaObject() : &staticMetaObject;
}

void *oclero::qlementine::QlementineStylePlugin::qt_metacast(const char *_clname)
{
    if (!_clname) return nullptr;
    if (!strcmp(_clname, qt_staticMetaObjectStaticContent<qt_meta_tag_ZN6oclero10qlementine21QlementineStylePluginE_t>.strings))
        return static_cast<void*>(this);
    return QStylePlugin::qt_metacast(_clname);
}

int oclero::qlementine::QlementineStylePlugin::qt_metacall(QMetaObject::Call _c, int _id, void **_a)
{
    _id = QStylePlugin::qt_metacall(_c, _id, _a);
    return _id;
}
using namespace oclero;
using namespace oclero::qlementine;

#ifdef QT_MOC_EXPORT_PLUGIN_V2
static constexpr unsigned char qt_pluginMetaDataV2_QlementineStylePlugin[] = {
    0xbf, 
    // "IID"
    0x02,  0x78,  0x28,  'o',  'r',  'g',  '.',  'q', 
    't',  '-',  'p',  'r',  'o',  'j',  'e',  'c', 
    't',  '.',  'Q',  't',  '.',  'Q',  'S',  't', 
    'y',  'l',  'e',  'F',  'a',  'c',  't',  'o', 
    'r',  'y',  'I',  'n',  't',  'e',  'r',  'f', 
    'a',  'c',  'e', 
    // "className"
    0x03,  0x75,  'Q',  'l',  'e',  'm',  'e',  'n', 
    't',  'i',  'n',  'e',  'S',  't',  'y',  'l', 
    'e',  'P',  'l',  'u',  'g',  'i',  'n', 
    // "MetaData"
    0x04,  0xa1,  0x64,  'K',  'e',  'y',  's',  0x81, 
    0x6a,  'q',  'l',  'e',  'm',  'e',  'n',  't', 
    'i',  'n',  'e', 
    0xff, 
};
QT_MOC_EXPORT_PLUGIN_V2(oclero::qlementine::QlementineStylePlugin, QlementineStylePlugin, qt_pluginMetaDataV2_QlementineStylePlugin)
#else
QT_PLUGIN_METADATA_SECTION
Q_CONSTINIT static constexpr unsigned char qt_pluginMetaData_QlementineStylePlugin[] = {
    'Q', 'T', 'M', 'E', 'T', 'A', 'D', 'A', 'T', 'A', ' ', '!',
    // metadata version, Qt version, architectural requirements
    0, QT_VERSION_MAJOR, QT_VERSION_MINOR, qPluginArchRequirements(),
    0xbf, 
    // "IID"
    0x02,  0x78,  0x28,  'o',  'r',  'g',  '.',  'q', 
    't',  '-',  'p',  'r',  'o',  'j',  'e',  'c', 
    't',  '.',  'Q',  't',  '.',  'Q',  'S',  't', 
    'y',  'l',  'e',  'F',  'a',  'c',  't',  'o', 
    'r',  'y',  'I',  'n',  't',  'e',  'r',  'f', 
    'a',  'c',  'e', 
    // "className"
    0x03,  0x75,  'Q',  'l',  'e',  'm',  'e',  'n', 
    't',  'i',  'n',  'e',  'S',  't',  'y',  'l', 
    'e',  'P',  'l',  'u',  'g',  'i',  'n', 
    // "MetaData"
    0x04,  0xa1,  0x64,  'K',  'e',  'y',  's',  0x81, 
    0x6a,  'q',  'l',  'e',  'm',  'e',  'n',  't', 
    'i',  'n',  'e', 
    0xff, 
};
QT_MOC_EXPORT_PLUGIN(oclero::qlementine::QlementineStylePlugin, QlementineStylePlugin)
#endif  // QT_MOC_EXPORT_PLUGIN_V2

QT_WARNING_POP
