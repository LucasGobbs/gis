/****************************************************************************
** Meta object code from reading C++ file 'editor.hpp'
**
** Created by: The Qt Meta Object Compiler version 69 (Qt 6.12.0)
**
** WARNING! All changes made in this file will be lost!
*****************************************************************************/

#include "../../../src/ui/editor.hpp"
#include <QtCore/qmetatype.h>

#include <QtCore/qtmochelpers.h>

#include <memory>


#include <QtCore/qxptype_traits.h>
#if !defined(Q_MOC_OUTPUT_REVISION)
#error "The header file 'editor.hpp' doesn't include <QObject>."
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
struct qt_meta_tag_ZN6editor6EditorE_t {};
} // unnamed namespace

template <> constexpr inline auto editor::Editor::qt_create_metaobjectdata<qt_meta_tag_ZN6editor6EditorE_t>()
{
    namespace QMC = QtMocConstants;
    QtMocHelpers::StringRefStorage qt_stringData {
        "editor::Editor",
        "status_changed",
        "",
        "status",
        "diagnostics_ready",
        "std::vector<editor::Diagnostic>",
        "diags",
        "font_changed",
        "pt",
        "split_toggled",
        "on",
        "tab_activated",
        "rel",
        "on_tab_changed",
        "index",
        "on_modified",
        "on_lsp_ready_read",
        "on_lsp_finished",
        "exit_code"
    };

    QtMocHelpers::UintData qt_methods {
        // Signal 'status_changed'
        QtMocHelpers::SignalData<void(const QString &)>(1, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 3 },
        }}),
        // Signal 'diagnostics_ready'
        QtMocHelpers::SignalData<void(const std::vector<editor::Diagnostic> &)>(4, 2, QMC::AccessPublic, QMetaType::Void, {{
            { 0x80000000 | 5, 6 },
        }}),
        // Signal 'font_changed'
        QtMocHelpers::SignalData<void(int)>(7, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 8 },
        }}),
        // Signal 'split_toggled'
        QtMocHelpers::SignalData<void(bool)>(9, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Bool, 10 },
        }}),
        // Signal 'tab_activated'
        QtMocHelpers::SignalData<void(const QString &)>(11, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 12 },
        }}),
        // Slot 'on_tab_changed'
        QtMocHelpers::SlotData<void(int)>(13, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::Int, 14 },
        }}),
        // Slot 'on_modified'
        QtMocHelpers::SlotData<void(int)>(15, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::Int, 14 },
        }}),
        // Slot 'on_lsp_ready_read'
        QtMocHelpers::SlotData<void()>(16, 2, QMC::AccessPrivate, QMetaType::Void),
        // Slot 'on_lsp_finished'
        QtMocHelpers::SlotData<void(int, int)>(17, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::Int, 18 }, { QMetaType::Int, 3 },
        }}),
    };
    QtMocHelpers::UintData qt_properties {
    };
    QtMocHelpers::UintData qt_enums {
    };
    return QtMocHelpers::metaObjectData<Editor, qt_meta_tag_ZN6editor6EditorE_t>(QMC::MetaObjectFlag{}, qt_stringData,
            qt_methods, qt_properties, qt_enums);
}
Q_CONSTINIT const QMetaObject editor::Editor::staticMetaObject = { {
    QMetaObject::SuperData::link<QTabWidget::staticMetaObject>(),
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN6editor6EditorE_t>.stringdata,
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN6editor6EditorE_t>.data,
    qt_static_metacall,
    nullptr,
    qt_staticMetaObjectRelocatingContent<qt_meta_tag_ZN6editor6EditorE_t>.metaTypes,
    nullptr
} };

void editor::Editor::qt_static_metacall(QObject *_o, QMetaObject::Call _c, int _id, void **_a)
{
    auto *_t = static_cast<Editor *>(_o);
    if (_c == QMetaObject::InvokeMetaMethod) {
        switch (_id) {
        case 0: _t->status_changed((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1]))); break;
        case 1: _t->diagnostics_ready((*reinterpret_cast<std::add_pointer_t<std::vector<editor::Diagnostic>>>(_a[1]))); break;
        case 2: _t->font_changed((*reinterpret_cast<std::add_pointer_t<int>>(_a[1]))); break;
        case 3: _t->split_toggled((*reinterpret_cast<std::add_pointer_t<bool>>(_a[1]))); break;
        case 4: _t->tab_activated((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1]))); break;
        case 5: _t->on_tab_changed((*reinterpret_cast<std::add_pointer_t<int>>(_a[1]))); break;
        case 6: _t->on_modified((*reinterpret_cast<std::add_pointer_t<int>>(_a[1]))); break;
        case 7: _t->on_lsp_ready_read(); break;
        case 8: _t->on_lsp_finished((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<int>>(_a[2]))); break;
        default: ;
        }
    }
    if (_c == QMetaObject::IndexOfMethod) {
        if (QtMocHelpers::indexOfMethod<void (Editor::*)(const QString & )>(_a, &Editor::status_changed, 0))
            return;
        if (QtMocHelpers::indexOfMethod<void (Editor::*)(const std::vector<editor::Diagnostic> & )>(_a, &Editor::diagnostics_ready, 1))
            return;
        if (QtMocHelpers::indexOfMethod<void (Editor::*)(int )>(_a, &Editor::font_changed, 2))
            return;
        if (QtMocHelpers::indexOfMethod<void (Editor::*)(bool )>(_a, &Editor::split_toggled, 3))
            return;
        if (QtMocHelpers::indexOfMethod<void (Editor::*)(const QString & )>(_a, &Editor::tab_activated, 4))
            return;
    }
}

const QMetaObject *editor::Editor::metaObject() const
{
    return QObject::d_ptr->metaObject ? QObject::d_ptr->dynamicMetaObject() : &staticMetaObject;
}

void *editor::Editor::qt_metacast(const char *_clname)
{
    if (!_clname) return nullptr;
    if (!strcmp(_clname, qt_staticMetaObjectStaticContent<qt_meta_tag_ZN6editor6EditorE_t>.strings))
        return static_cast<void*>(this);
    return QTabWidget::qt_metacast(_clname);
}

int editor::Editor::qt_metacall(QMetaObject::Call _c, int _id, void **_a)
{
    _id = QTabWidget::qt_metacall(_c, _id, _a);
    if (_id < 0)
        return _id;
    if (_c == QMetaObject::InvokeMetaMethod) {
        if (_id < 9)
            qt_static_metacall(this, _c, _id, _a);
        _id -= 9;
    }
    if (_c == QMetaObject::RegisterMethodArgumentMetaType) {
        if (_id < 9)
            *reinterpret_cast<QMetaType *>(_a[0]) = QMetaType();
        _id -= 9;
    }
    return _id;
}

// SIGNAL 0
void editor::Editor::status_changed(const QString & _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 0, nullptr, _t1);
}

// SIGNAL 1
void editor::Editor::diagnostics_ready(const std::vector<editor::Diagnostic> & _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 1, nullptr, _t1);
}

// SIGNAL 2
void editor::Editor::font_changed(int _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 2, nullptr, _t1);
}

// SIGNAL 3
void editor::Editor::split_toggled(bool _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 3, nullptr, _t1);
}

// SIGNAL 4
void editor::Editor::tab_activated(const QString & _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 4, nullptr, _t1);
}
QT_WARNING_POP
