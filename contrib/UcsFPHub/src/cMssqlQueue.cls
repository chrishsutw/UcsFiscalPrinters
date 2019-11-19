VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "cMssqlQueue"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
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
Private Const MODULE_NAME As String = "cMssqlQueue"
Implements IQueue

'=========================================================================
' Constants and member variables
'=========================================================================

Private Const STR_SVC_PREFIX            As String = "UcsFpTargetService"
Private Const STR_QUEUE_SETUP           As String = "������ %1 ����� �� %2 ������"
Private Const STR_QUEUE_TERMINATE       As String = "O����� %1 � �����������"
Private Const STR_QUEUE_HEARTBEAT       As String = "O����� %1 �� ���� ������������ (�� �������� � ������� �� %2 ���.)"
Private Const STR_QUEUE_ERROR           As String = "������ %1 �� ������� %2 ����� ������ %3"
Private Const STR_QUEUE_LOOP            As String = "DECLARE     @QueueName SYSNAME = '%1', @Result INT, @Handle UNIQUEIDENTIFIER, @Request NVARCHAR(MAX), @MsgType SYSNAME, @SvcName SYSNAME, @ErrorText NVARCHAR(255)" & vbCrLf & _
                                                    "EXEC        @Result = dbo.usp_sys_ServiceBrokerWaitRequest @QueueName, %2, @Handle OUTPUT, @Request OUTPUT, @MsgType OUTPUT, @SvcName OUTPUT, @ErrorText OUTPUT" & vbCrLf & _
                                                    "SELECT      @Result AS Result, @Handle AS Handle, @Request AS Request, @MsgType AS MsgType, @SvcName AS SvcName, @ErrorText AS ErrorText" & vbCrLf & _
                                                    "RAISERROR   ('Result=%d', 10, 0, @Result) WITH NOWAIT" & vbCrLf
Private Const LNG_QUEUE_FIELDS          As Long = 6
Private Const STR_SEND_ON_CONV          As String = "SEND ON CONVERSATION '%1' (N'%2')"
Private Const STR_END_CONV_WITH_ERROR   As String = "END CONVERSATION '%1' WITH ERROR = %2 DESCRIPTION = '%3'"
Private Const ERR_UNKNOWN               As String = "���������� ������ %1"
'--- numeric
Private Const ERR_DB_E_NOTABLE          As Long = &H80040E37

Private m_pTimer                    As IUnknown
Attribute m_pTimer.VB_VarHelpID = -1
Private WithEvents m_oConn          As ADODB.Connection
Attribute m_oConn.VB_VarHelpID = -1
Private m_vPrinters                 As Variant
Private m_sQueueName                As String
Private m_lQueueTimeout             As Long
Private m_oCallback                 As cQueueEndpoint
Private m_sLastError                As String
Private m_sSqlInstance              As String
Private m_sSqlDatabase              As String

'=========================================================================
' Error handling
'=========================================================================

Private Sub PrintError(sFunction As String)
    m_sLastError = Err.Description
    #If USE_DEBUG_LOG <> 0 Then
        DebugLog Err.Description & " &H" & Hex$(Err.Number) & " [" & MODULE_NAME & "." & sFunction & "(" & m_sSqlInstance & "/" & m_sSqlDatabase & ")(" & Erl & ")]", vbLogEventTypeError
    #Else
        Debug.Print "Critical error: " & Err.Description & " [" & MODULE_NAME & "." & sFunction & "]"
    #End If
End Sub

'=========================================================================
' Properties
'=========================================================================

Property Get LastError() As String
    LastError = m_sLastError
End Property

Private Property Get pvAddressOfTimerProc() As cMssqlQueue
    Set pvAddressOfTimerProc = InitAddressOfMethod(Me, 0)
End Property

'=========================================================================
' Methods
'=========================================================================

Public Function Init(oConn As Object, vPrinters As Variant, sQueueName As String, ByVal lQueueTimeout As Long, oCallback As Object) As Boolean
    Const FUNC_NAME     As String = "Init"
    
    On Error GoTo EH
    Set m_oConn = oConn
    m_vPrinters = vPrinters
    m_sQueueName = sQueueName
    m_lQueueTimeout = lQueueTimeout
    Set m_oCallback = oCallback
    If pvIsConnAlive(m_oConn) Then
        pvQueueSetup
        pvQueueLoopAsync
        pvRestartTimer
        '--- success
        Init = True
    End If
    Exit Function
EH:
    PrintError FUNC_NAME
End Function

Private Function pvQueueSetup() As Boolean
    Const FUNC_NAME     As String = "pvQueueSetup"
    Dim lPos            As Long
    Dim lIdx            As Long
    Dim vElem           As Variant
    
    On Error GoTo EH
    lPos = InStr(m_sQueueName, "/")
    m_oConn.usp_sys_ServiceBrokerSetupService m_sQueueName, STR_SVC_PREFIX & Mid$(m_sQueueName, lPos), "DROP_EXISTING"
    lIdx = lIdx + 1
    For Each vElem In m_vPrinters
        If LenB(C_Str(vElem)) <> 0 Then
            m_oConn.usp_sys_ServiceBrokerSetupService m_sQueueName, STR_SVC_PREFIX & "/" & C_Str(vElem), "DROP_SERVICE"
            lIdx = lIdx + 1
        End If
    Next
    DebugLog Printf(STR_QUEUE_SETUP, m_sQueueName, lIdx) & " [" & MODULE_NAME & "." & FUNC_NAME & "]"
    '--- success
    pvQueueSetup = True
    Exit Function
EH:
    PrintError FUNC_NAME
End Function

Private Function pvQueueLoopAsync() As Boolean
    Const FUNC_NAME     As String = "pvQueueLoopAsync"
    
    On Error GoTo EH
    m_oConn.Execute Printf(STR_QUEUE_LOOP, m_sQueueName, m_lQueueTimeout), , adAsyncExecute Or adAsyncFetch
    '--- success
    pvQueueLoopAsync = True
    Exit Function
EH:
    PrintError FUNC_NAME
End Function

Private Function pvQueueTerminate() As Boolean
    Const FUNC_NAME     As String = "pvQueueTerminate"
    Dim lPos            As Long
    On Error GoTo EH
    If Not m_oConn Is Nothing Then
        If (m_oConn.State And adStateExecuting) <> 0 Then
            m_oConn.Cancel
        End If
        lPos = InStr(m_sQueueName, "/")
        m_oConn.usp_sys_ServiceBrokerSetupService m_sQueueName, STR_SVC_PREFIX & Mid$(m_sQueueName, lPos), "DROP_ONLY"
        DebugLog Printf(STR_QUEUE_TERMINATE, m_sQueueName) & " [" & MODULE_NAME & "." & FUNC_NAME & "]"
    End If
    '--- success
    pvQueueTerminate = True
    Exit Function
EH:
    PrintError FUNC_NAME
End Function

Public Function pvIsConnAlive(cn As ADODB.Connection) As Boolean
    On Error GoTo QH
    With cn.Execute("SELECT @@SERVERNAME, DB_NAME()")
        m_sSqlInstance = .Fields(0).Value
        m_sSqlDatabase = .Fields(1).Value
    End With
    '--- success
    pvIsConnAlive = True
QH:
End Function

Public Function TimerProc() As Long
    Const FUNC_NAME     As String = "TimerProc"
    Dim oConn           As Object
    
    On Error GoTo EH
    '--- if heart-beat timer is reached -> bad things must have happened to connection so re-open it
    DebugLog Printf(STR_QUEUE_HEARTBEAT, m_sQueueName, (m_lQueueTimeout + 3000) / 1000) & " [" & MODULE_NAME & "." & FUNC_NAME & "]"
    pvQueueTerminate
    If m_oCallback.frReopenConn(oConn) Then
        Set m_oConn = oConn
        pvQueueLoopAsync
    End If
    pvRestartTimer
    Exit Function
EH:
    PrintError FUNC_NAME
    Resume Next
End Function

Private Sub pvRestartTimer()
    Const FUNC_NAME     As String = "pvRestartTimer"
    
    On Error GoTo EH
    '--- start heart-beat timer
    Set m_pTimer = InitFireOnceTimerThunk(Me, pvAddressOfTimerProc.TimerProc, Delay:=m_lQueueTimeout + 3000)
    Exit Sub
EH:
    PrintError FUNC_NAME
    Resume Next
End Sub

'=========================================================================
' Events
'=========================================================================

Private Sub m_oConn_ExecuteComplete(ByVal RecordsAffected As Long, ByVal pError As ADODB.Error, adStatus As ADODB.EventStatusEnum, ByVal pCommand As ADODB.Command, ByVal pRecordset As ADODB.Recordset, ByVal pConnection As ADODB.Connection)
    Const FUNC_NAME     As String = "m_oConn_ExecuteComplete"
    Static bHere        As Boolean
    Dim sHandle         As String
    Dim sResponse       As String
    Dim lErrorCode      As Long
    Dim sPrinterId      As String
    Dim vErr            As Variant
    
    On Error GoTo EH
    If bHere Then
        Exit Sub
    End If
    bHere = True
    If Not pError Is Nothing Then
        vErr = Array(pError.Number, pError.Source, pError.Description)
        If vErr(0) <> ERR_DB_E_NOTABLE And vErr(0) <> adErrOperationCancelled Then
            DebugLog pError.Description & " [" & MODULE_NAME & "." & FUNC_NAME & "]", vbLogEventTypeError
        End If
        GoTo NextLine
    ElseIf Not pRecordset Is Nothing Then
        If (pRecordset.State And adStateOpen) <> 0 Then
            If pRecordset.Fields.Count = LNG_QUEUE_FIELDS Then
                pvQueueLoopAsync
                pvRestartTimer
                sHandle = C_Str(pRecordset!Handle.Value)
                If C_Lng(pRecordset!Result.Value) = 0 And LenB(sHandle) <> 0 Then
                    If m_oCallback.frHandleRequest(C_Str(pRecordset!SvcName.Value), C_Str(pRecordset!Request.Value), sResponse, lErrorCode) Then
                        m_oConn.Execute Printf(STR_SEND_ON_CONV, Quote(sHandle), Quote(sResponse))
                    Else
                        m_oConn.Execute Printf(STR_END_CONV_WITH_ERROR, Quote(sHandle), Znl(lErrorCode, 500), _
                            Quote(Zn(sResponse, Printf(ERR_UNKNOWN, lErrorCode))))
                    End If
                ElseIf C_Lng(pRecordset!Result.Value) <> 99 Then
                    sResponse = C_Str(pRecordset!ErrorText.Value)
                    If LenB(sResponse) <> 0 Then
                        sPrinterId = At(Split(C_Str(pRecordset!SvcName.Value), "/"), 1)
                        DebugLog Printf(STR_QUEUE_ERROR, m_sQueueName, sPrinterId, sResponse) & " [" & MODULE_NAME & "." & FUNC_NAME & "]", vbLogEventTypeError
                    End If
                End If
            End If
        End If
    End If
QH:
    bHere = False
    Exit Sub
EH:
    vErr = Array(Err.Number, Err.Source, Err.Description)
    If vErr(0) <> ERR_DB_E_NOTABLE And vErr(0) <> adErrOperationCancelled Then
        PrintError FUNC_NAME
    End If
    Resume NextLine
NextLine:
    On Error Resume Next
    If pvIsConnAlive(m_oConn) Then
        If vErr(0) = ERR_DB_E_NOTABLE Then
            pvQueueSetup
        End If
        If LenB(sHandle) <> 0 Then
            m_oConn.Execute Printf(STR_END_CONV_WITH_ERROR, Quote(sHandle), Znl(lErrorCode, 500), _
                Quote(Zn(m_sLastError, Printf(ERR_UNKNOWN, lErrorCode))))
        End If
        pvQueueLoopAsync
        pvRestartTimer
    End If
    GoTo QH
End Sub

'=========================================================================
' IQueue interface
'=========================================================================

Private Function IQueue_Setup() As Boolean
    IQueue_Setup = pvQueueSetup
End Function

Private Function IQueue_LoopAsync() As Boolean
    IQueue_LoopAsync = pvQueueLoopAsync
End Function

Private Function IQueue_Terminate() As Boolean
    IQueue_Terminate = pvQueueTerminate
End Function