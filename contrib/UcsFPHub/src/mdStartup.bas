Attribute VB_Name = "mdStartup"
'=========================================================================
'
' UcsFPHub (c) 2019 by Unicontsoft
'
' Unicontsoft Fiscal Printers Hub
'
' This project is licensed under the terms of the MIT license
' See the LICENSE file in the project root for more information
'
'=========================================================================
Option Explicit
DefObj A-Z
Private Const MODULE_NAME As String = "mdStartup"

'=========================================================================
' API
'=========================================================================

Private Declare Sub ExitProcess Lib "kernel32" (ByVal uExitCode As Long)
Private Declare Function GetModuleFileName Lib "kernel32" Alias "GetModuleFileNameA" (ByVal hModule As Long, ByVal lpFileName As String, ByVal nSize As Long) As Long

'=========================================================================
' Constants and member variables
'=========================================================================

Private Const STR_VERSION           As String = "0.1.1"
Private Const STR_SERVICE_NAME      As String = "UcsFPHub"
Private Const STR_DISPLAY_NAME      As String = "Unicontsoft Fiscal Printers Hub " & STR_VERSION
Private Const STR_AUTODETECTING_PRINTERS As String = "����������� ������� �� ��������..."
Private Const STR_PRINTERS_FOUND    As String = "�������� %1 ��������"
Private Const STR_PRESS_CTRLC       As String = "��������� Ctrl+C �� �����"
Private Const STR_LOADING_CONFIG    As String = "������� ������������ �� %1"
'--- errors
Private Const ERR_CONFIG_NOT_FOUND  As String = "������: ��������������� ���� %1 �� � �������"
Private Const ERR_PARSING_CONFIG    As String = "������: ��������� %1: %2"
Private Const ERR_ENUM_PORTS        As String = "������: ����������� �� ������� �������: %1"
Private Const ERR_WARN_ACCESS       As String = "��������������: ������� %1: %2"

Private m_oOpt                  As Object
Private m_oPrinters             As Object
Private m_cEndpoints            As Collection
Private m_bIsService            As Boolean

'=========================================================================
' Error handling
'=========================================================================

Private Sub PrintError(sFunction As String)
    Debug.Print "Critical error: " & Err.Description & " [" & MODULE_NAME & "." & sFunction & "]"
End Sub

'=========================================================================
' Functions
'=========================================================================

Private Sub Main()
    Dim lExitCode       As Long
    
    lExitCode = Process(SplitArgs(Command$))
    If Not InIde Then
        Call ExitProcess(lExitCode)
    End If
End Sub

Private Function Process(vArgs As Variant) As Long
    Const FUNC_NAME     As String = "Process"
    Dim sConfFile       As String
    Dim sError          As String
    Dim oConfig         As Object
    
    On Error GoTo EH
    Set m_oOpt = GetOpt(vArgs, "conf:c")
    If Not m_oOpt.Item("--nologo") Then
        DebugLog App.ProductName & " " & STR_VERSION & " (c) 2019 by Unicontsoft" & vbCrLf
    End If
    sConfFile = Zn(m_oOpt.Item("--conf"), m_oOpt.Item("-c"))
    If NtServiceInit(STR_SERVICE_NAME) Then
        m_bIsService = True
    ElseIf m_oOpt.Item("--install") Or m_oOpt.Item("-i") Then
        DebugLog Printf("Installing %1...", STR_SERVICE_NAME)
        If LenB(sConfFile) <> 0 Then
            sConfFile = " -c " & ArgvQuote(sConfFile)
        End If
        If Not NtServiceInstall(STR_SERVICE_NAME, STR_DISPLAY_NAME, GetProcessName() & sConfFile, Error:=sError) Then
            DebugLog sError
        Else
            DebugLog "Success"
        End If
        GoTo QH
    ElseIf m_oOpt.Item("--uninstall") Or m_oOpt.Item("-u") Then
        DebugLog Printf("Uninstalling %1...", STR_SERVICE_NAME)
        If Not NtServiceUninstall(STR_SERVICE_NAME, Error:=sError) Then
            DebugLog sError
        Else
            DebugLog "Success"
        End If
        GoTo QH
    End If
    If LenB(sConfFile) = 0 Then
        sConfFile = PathCombine(App.Path, App.EXEName & ".conf")
        If Not FileExists(sConfFile) Then
            sConfFile = vbNullString
        End If
    End If
    If LenB(sConfFile) <> 0 Then
        DebugLog Printf(STR_LOADING_CONFIG, sConfFile)
        If Not FileExists(sConfFile) Then
            DebugLog Printf(ERR_CONFIG_NOT_FOUND, sConfFile), vbLogEventTypeError
            Process = 1
            GoTo QH
        End If
        If Not JsonParse(FromUtf8Array(ReadBinaryFile(sConfFile)), oConfig, Error:=sError) Then
            DebugLog Printf(ERR_PARSING_CONFIG, sConfFile, sError), vbLogEventTypeError
            Process = 1
            GoTo QH
        End If
    Else
        JsonItem(oConfig, "Printers/Autodetect") = True
        JsonItem(oConfig, "Endpoints/0/Binding") = "RestHttp"
        JsonItem(oConfig, "Endpoints/0/Address") = "127.0.0.1:8192"
    End If
    Set m_oPrinters = pvCollectPrinters(oConfig)
    DebugLog Printf(STR_PRINTERS_FOUND, JsonItem(m_oPrinters, "Count"))
    DebugLog JsonDump(m_oPrinters)
    Set m_cEndpoints = pvCreateEndpoints(oConfig, m_oPrinters)
    If InIde Then
        frmIcon.Show vbModal
    ElseIf m_bIsService Then
        Do While Not NtServiceQueryStop()
            '--- do nothing
        Loop
        NtServiceTerminate
    Else
        DebugLog STR_PRESS_CTRLC
        Do
            ConsoleRead
            DoEvents
        Loop
    End If
QH:
    Exit Function
EH:
    PrintError FUNC_NAME
    Process = 100
End Function

Private Function pvCollectPrinters(oConfig As Object) As Object
    Const FUNC_NAME     As String = "pvCollectPrinters"
    Dim oFP             As cFiscalPrinter
    Dim sResponse       As String
    Dim oJson           As Object
    Dim vKey            As Variant
    Dim oRequest        As Object
    Dim oRetVal         As Object
    Dim sDeviceString   As String
    Dim sKey            As String
    
    On Error GoTo EH
    Set oFP = New cFiscalPrinter
    JsonItem(oRetVal, "Count") = 0
    If JsonItem(oConfig, "Printers/Autodetect") Then
        DebugLog STR_AUTODETECTING_PRINTERS
        If oFP.EnumPorts(sResponse) And JsonParse(sResponse, oJson) Then
            If Not JsonItem(oJson, "Ok") Then
                DebugLog Printf(ERR_ENUM_PORTS, vKey, JsonItem(oJson, "ErrorText")), vbLogEventTypeError
            Else
                For Each vKey In JsonKeys(oJson, "SerialPorts")
                    If LenB(JsonItem(oJson, "SerialPorts/" & vKey & "/Protocol")) <> 0 Then
                        sDeviceString = "Protocol=" & JsonItem(oJson, "SerialPorts/" & vKey & "/Protocol") & _
                            ";Port=" & JsonItem(oJson, "SerialPorts/" & vKey & "/Port") & _
                            ";Speed=" & JsonItem(oJson, "SerialPorts/" & vKey & "/Speed")
                        Set oRequest = Nothing
                        JsonItem(oRequest, "DeviceString") = sDeviceString
                        JsonItem(oRequest, "IncludeTaxNo") = True
                        If oFP.GetDeviceInfo(JsonDump(oRequest, Minimize:=True), sResponse) And JsonParse(sResponse, oJson) Then
                            sKey = JsonItem(oJson, "DeviceSerialNo")
                            If LenB(sKey) <> 0 Then
                                JsonItem(oJson, "Ok") = Empty
                                JsonItem(oJson, "DeviceString") = sDeviceString
                                JsonItem(oRetVal, sKey) = oJson
                                JsonItem(oRetVal, "Count") = JsonItem(oRetVal, "Count") + 1
                            End If
                        End If
                    End If
                Next
            End If
        End If
    End If
    For Each vKey In JsonKeys(oConfig, "Printers")
        sDeviceString = C_Str(JsonItem(oConfig, "Printers/" & vKey & "/DeviceString"))
        If LenB(sDeviceString) <> 0 Then
            Set oRequest = Nothing
            JsonItem(oRequest, "DeviceString") = sDeviceString
            JsonItem(oRequest, "IncludeTaxNo") = True
            If oFP.GetDeviceInfo(JsonDump(oRequest, Minimize:=True), sResponse) And JsonParse(sResponse, oJson) Then
                If Not JsonItem(oJson, "Ok") Then
                    DebugLog Printf(ERR_WARN_ACCESS, vKey, JsonItem(oJson, "ErrorText")), vbLogEventTypeWarning
                Else
                    sKey = JsonItem(oJson, "DeviceSerialNo")
                    If LenB(sKey) <> 0 Then
                        JsonItem(oJson, "Ok") = Empty
                        JsonItem(oJson, "DeviceString") = sDeviceString
                        JsonItem(oRetVal, sKey) = oJson
                        JsonItem(oRetVal, "Count") = JsonItem(oRetVal, "Count") + 1
                        JsonItem(oRetVal, "Aliases/Count") = JsonItem(oRetVal, "Aliases/Count") + 1
                        JsonItem(oRetVal, "Aliases/" & vKey & "/DeviceSerialNo") = sKey
                    End If
                End If
            End If
        End If
    Next
    Set pvCollectPrinters = oRetVal
    Exit Function
EH:
    PrintError FUNC_NAME
    Resume Next
End Function

Private Function pvCreateEndpoints(oConfig As Object, oPrinters As Object) As Collection
    Const FUNC_NAME     As String = "pvCreateEndpoints"
    Dim cRetVal         As Collection
    Dim vKey            As Variant
    Dim oRestEndpoint   As cRestEndpoint
    
    On Error GoTo EH
    Set cRetVal = New Collection
    For Each vKey In JsonKeys(oConfig, "Endpoints")
        Select Case LCase$(JsonItem(oConfig, "Endpoints/" & vKey & "/Binding"))
        Case "resthttp"
            Set oRestEndpoint = New cRestEndpoint
            If oRestEndpoint.Init(JsonItem(oConfig, "Endpoints/" & vKey), oPrinters) Then
                cRetVal.Add oRestEndpoint
            End If
        Case "mssqlservicebroker"
            '--- ToDo: impl
        End Select
    Next
    Set pvCreateEndpoints = cRetVal
    Exit Function
EH:
    PrintError FUNC_NAME
    Resume Next
End Function

Private Function GetProcessName() As String
    GetProcessName = String$(1000, 0)
    Call GetModuleFileName(0, GetProcessName, Len(GetProcessName) - 1)
    GetProcessName = Left$(GetProcessName, InStr(GetProcessName, vbNullChar) - 1)
End Function

Public Sub DebugLog(sText As String, Optional ByVal eType As LogEventTypeConstants = vbLogEventTypeInformation)
    If m_bIsService Then
        App.LogEvent sText, eType
    ElseIf eType = vbLogEventTypeError Then
        ConsoleColorError FOREGROUND_RED, FOREGROUND_MASK, sText & vbCrLf
    Else
        ConsolePrint sText & vbCrLf
    End If
End Sub
