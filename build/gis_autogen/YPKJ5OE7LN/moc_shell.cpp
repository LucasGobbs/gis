/****************************************************************************
** Meta object code from reading C++ file 'shell.hpp'
**
** Created by: The Qt Meta Object Compiler version 69 (Qt 6.12.0)
**
** WARNING! All changes made in this file will be lost!
*****************************************************************************/

#include "../../../src/ui/shell.hpp"
#include <QtCore/qmetatype.h>

#include <QtCore/qtmochelpers.h>

#include <memory>


#include <QtCore/qxptype_traits.h>
#if !defined(Q_MOC_OUTPUT_REVISION)
#error "The header file 'shell.hpp' doesn't include <QObject>."
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
struct qt_meta_tag_ZN5shell5ShellE_t {};
} // unnamed namespace

template <> constexpr inline auto shell::Shell::qt_create_metaobjectdata<qt_meta_tag_ZN5shell5ShellE_t>()
{
    namespace QMC = QtMocConstants;
    QtMocHelpers::StringRefStorage qt_stringData {
        "shell::Shell",
        "scene_selected",
        "",
        "index",
        "scene_open_requested",
        "title",
        "pause_toggled",
        "save_all_requested",
        "png_export_requested",
        "gif_export_requested",
        "start_s",
        "end_s",
        "camera_reset_requested",
        "mode_changed",
        "shell::Sidebar_Mode",
        "mode",
        "preferences_requested",
        "close_requested",
        "popup_mouse_shield",
        "on",
        "refresh_scenes"
    };

    QtMocHelpers::UintData qt_methods {
        // Signal 'scene_selected'
        QtMocHelpers::SignalData<void(int)>(1, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 3 },
        }}),
        // Signal 'scene_open_requested'
        QtMocHelpers::SignalData<void(const QString &)>(4, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 5 },
        }}),
        // Signal 'pause_toggled'
        QtMocHelpers::SignalData<void()>(6, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'save_all_requested'
        QtMocHelpers::SignalData<void()>(7, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'png_export_requested'
        QtMocHelpers::SignalData<void()>(8, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'gif_export_requested'
        QtMocHelpers::SignalData<void(float, float)>(9, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Float, 10 }, { QMetaType::Float, 11 },
        }}),
        // Signal 'camera_reset_requested'
        QtMocHelpers::SignalData<void()>(12, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'mode_changed'
        QtMocHelpers::SignalData<void(shell::Sidebar_Mode)>(13, 2, QMC::AccessPublic, QMetaType::Void, {{
            { 0x80000000 | 14, 15 },
        }}),
        // Signal 'preferences_requested'
        QtMocHelpers::SignalData<void()>(16, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'close_requested'
        QtMocHelpers::SignalData<void()>(17, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'popup_mouse_shield'
        QtMocHelpers::SignalData<void(bool)>(18, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Bool, 19 },
        }}),
        // Slot 'refresh_scenes'
        QtMocHelpers::SlotData<void()>(20, 2, QMC::AccessPublic, QMetaType::Void),
    };
    QtMocHelpers::UintData qt_properties {
    };
    QtMocHelpers::UintData qt_enums {
    };
    return QtMocHelpers::metaObjectData<Shell, qt_meta_tag_ZN5shell5ShellE_t>(QMC::MetaObjectFlag{}, qt_stringData,
            qt_methods, qt_properties, qt_enums);
}
Q_CONSTINIT const QMetaObject shell::Shell::staticMetaObject = { {
    QMetaObject::SuperData::link<QWidget::staticMetaObject>(),
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN5shell5ShellE_t>.stringdata,
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN5shell5ShellE_t>.data,
    qt_static_metacall,
    nullptr,
    qt_staticMetaObjectRelocatingContent<qt_meta_tag_ZN5shell5ShellE_t>.metaTypes,
    nullptr
} };

void shell::Shell::qt_static_metacall(QObject *_o, QMetaObject::Call _c, int _id, void **_a)
{
    auto *_t = static_cast<Shell *>(_o);
    if (_c == QMetaObject::InvokeMetaMethod) {
        switch (_id) {
        case 0: _t->scene_selected((*reinterpret_cast<std::add_pointer_t<int>>(_a[1]))); break;
        case 1: _t->scene_open_requested((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1]))); break;
        case 2: _t->pause_toggled(); break;
        case 3: _t->save_all_requested(); break;
        case 4: _t->png_export_requested(); break;
        case 5: _t->gif_export_requested((*reinterpret_cast<std::add_pointer_t<float>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<float>>(_a[2]))); break;
        case 6: _t->camera_reset_requested(); break;
        case 7: _t->mode_changed((*reinterpret_cast<std::add_pointer_t<shell::Sidebar_Mode>>(_a[1]))); break;
        case 8: _t->preferences_requested(); break;
        case 9: _t->close_requested(); break;
        case 10: _t->popup_mouse_shield((*reinterpret_cast<std::add_pointer_t<bool>>(_a[1]))); break;
        case 11: _t->refresh_scenes(); break;
        default: ;
        }
    }
    if (_c == QMetaObject::IndexOfMethod) {
        if (QtMocHelpers::indexOfMethod<void (Shell::*)(int )>(_a, &Shell::scene_selected, 0))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)(const QString & )>(_a, &Shell::scene_open_requested, 1))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)()>(_a, &Shell::pause_toggled, 2))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)()>(_a, &Shell::save_all_requested, 3))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)()>(_a, &Shell::png_export_requested, 4))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)(float , float )>(_a, &Shell::gif_export_requested, 5))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)()>(_a, &Shell::camera_reset_requested, 6))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)(shell::Sidebar_Mode )>(_a, &Shell::mode_changed, 7))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)()>(_a, &Shell::preferences_requested, 8))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)()>(_a, &Shell::close_requested, 9))
            return;
        if (QtMocHelpers::indexOfMethod<void (Shell::*)(bool )>(_a, &Shell::popup_mouse_shield, 10))
            return;
    }
}

const QMetaObject *shell::Shell::metaObject() const
{
    return QObject::d_ptr->metaObject ? QObject::d_ptr->dynamicMetaObject() : &staticMetaObject;
}

void *shell::Shell::qt_metacast(const char *_clname)
{
    if (!_clname) return nullptr;
    if (!strcmp(_clname, qt_staticMetaObjectStaticContent<qt_meta_tag_ZN5shell5ShellE_t>.strings))
        return static_cast<void*>(this);
    return QWidget::qt_metacast(_clname);
}

int shell::Shell::qt_metacall(QMetaObject::Call _c, int _id, void **_a)
{
    _id = QWidget::qt_metacall(_c, _id, _a);
    if (_id < 0)
        return _id;
    if (_c == QMetaObject::InvokeMetaMethod) {
        if (_id < 12)
            qt_static_metacall(this, _c, _id, _a);
        _id -= 12;
    }
    if (_c == QMetaObject::RegisterMethodArgumentMetaType) {
        if (_id < 12)
            *reinterpret_cast<QMetaType *>(_a[0]) = QMetaType();
        _id -= 12;
    }
    return _id;
}

// SIGNAL 0
void shell::Shell::scene_selected(int _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 0, nullptr, _t1);
}

// SIGNAL 1
void shell::Shell::scene_open_requested(const QString & _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 1, nullptr, _t1);
}

// SIGNAL 2
void shell::Shell::pause_toggled()
{
    QMetaObject::activate(this, &staticMetaObject, 2, nullptr);
}

// SIGNAL 3
void shell::Shell::save_all_requested()
{
    QMetaObject::activate(this, &staticMetaObject, 3, nullptr);
}

// SIGNAL 4
void shell::Shell::png_export_requested()
{
    QMetaObject::activate(this, &staticMetaObject, 4, nullptr);
}

// SIGNAL 5
void shell::Shell::gif_export_requested(float _t1, float _t2)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 5, nullptr, _t1, _t2);
}

// SIGNAL 6
void shell::Shell::camera_reset_requested()
{
    QMetaObject::activate(this, &staticMetaObject, 6, nullptr);
}

// SIGNAL 7
void shell::Shell::mode_changed(shell::Sidebar_Mode _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 7, nullptr, _t1);
}

// SIGNAL 8
void shell::Shell::preferences_requested()
{
    QMetaObject::activate(this, &staticMetaObject, 8, nullptr);
}

// SIGNAL 9
void shell::Shell::close_requested()
{
    QMetaObject::activate(this, &staticMetaObject, 9, nullptr);
}

// SIGNAL 10
void shell::Shell::popup_mouse_shield(bool _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 10, nullptr, _t1);
}
QT_WARNING_POP
