//
//Copyright Larry Tyree, N6TR, 2011,2012,2013,2014,2015.
//
//This file is part of TR log for linux.
//
//TR log for linux is free software: you can redistribute it and/or
//modify it under the terms of the GNU General Public License as
//published by the Free Software Foundation, either version 2 of the
//License, or (at your option) any later version.
//
//TR log for linux is distributed in the hope that it will be useful,
//but WITHOUT ANY WARRANTY; without even the implied warranty of
//MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//GNU General Public License for more details.
//
//You should have received a copy of the GNU General
//    Public License along with TR log for linux.  If not, see
//<http://www.gnu.org/licenses/>.
//

UNIT N1MM;

{ Here we have various routines that are used when interfacing to N1MM over
  the LAN. Currently - the only operation that can be performmed is to listen
  to a UDP port for QSO information.

  The necessary routine to log the QSO is also here. }

{$O+}
{$V-}

INTERFACE

USES LogStuff, LogUDP, LogWind, LogDupe, LogEdit, SlowTree, datetimec, Tree, KeyCode,
     Country9, Sockets, UnixType, BaseUnix, portname;

CONST UDPBufferSize = 4096;

TYPE
    N1MM_Object = OBJECT
        NumberCharsInUDPBuffer: INTEGER;
        Socket: LONGINT;
        UDP_PortNumber: LONGINT;
        UDP_Socket: LONGINT;
        UDPBuffer: ARRAY [0..UDPBufferSize -1] OF CHAR;

        FUNCTION  Check_UDP_Port: BOOLEAN;
        FUNCTION  CreateRXDataFromUDPMessage (VAR RXData: ContestExchange): BOOLEAN;
        PROCEDURE GetBandAndModeFromUDPMessage (VAR RXData: ContestExchange);
        PROCEDURE GetCallFromUDPMessage (VAR RXData: ContestExchange);
        PROCEDURE GetExchangeDataFromUDPMessage (VAR RXData: ContestExchange);
        PROCEDURE GetFrequencyFromUDPMessage (VAR RXData: ContestExchange);
        PROCEDURE GetTimeAndDateFromUDPMessage (VAR RXData: ContestExchange);
        FUNCTION  GetXMLData (XMLField: STRING): STRING;
        PROCEDURE Heartbeat;
        PROCEDURE Init;
        PROCEDURE LogContact;
        PROCEDURE LogN1MMContact (RXData: ContestExchange);  { Logs the QSO }
        FUNCTION  NextBytesMatchString (Address: INTEGER; Pattern: STRING): BOOLEAN;
        PROCEDURE PushLogStringIntoEditableLogAndLogPopedQSO (LogString: Str80; MyQSO: BOOLEAN);
        PROCEDURE PutContactIntoLogFile (LogString: Str80);
        END;

VAR  N1MM_QSO_Portal: N1MM_Object;

IMPLEMENTATION

CONST N1MM_DebugFileName = 'N1MM_debug.txt';



FUNCTION N1MM_Object.NextBytesMatchString (Address: INTEGER; Pattern: STRING): BOOLEAN;

VAR PatternIndex: INTEGER;

    BEGIN
    IF Length (Pattern) = 0 THEN
        BEGIN
        NextBytesMatchString := False;
        Exit;
        END;

    PatternIndex := 1;

    WHILE Address < NumberCharsInUDPBuffer DO
        BEGIN
        IF UDPBuffer [Address] <> Pattern [PatternIndex] THEN
            BEGIN
            NextBytesMatchString := False;
            Exit;
            END;

        { We have a match - see if we have matched up all of the Pattern }

        IF PatternIndex = Length (Pattern) THEN
            BEGIN
            NextBytesMatchString := True;
            Exit;
            END;

        { Increment to the next character in the buffer and pattern }

        Inc (PatternIndex);
        Inc (Address);
        END;

    { Failed to find a match before running out of characters }

    NextBytesMatchString := False;
    END;



FUNCTION N1MM_Object.GetXMLData (XMLField: STRING): STRING;

{ Will look through the buffer for a match of the XMLField indicated and return any
  data found.  A nullstring indicates either the field was not included or there was
  no data found. }

VAR StartAddress, StopAddress, SaveAddress, Address: INTEGER;
    TempString: STRING;

    BEGIN
    GetXMLData := '';

    IF NumberCharsInUDPBuffer < (Length (XMLField) *2) THEN Exit;  { Not enough bytes }

    Address := 0; { First byte of buffer }

    WHILE Address < NumberCharsInUDPBuffer DO
        BEGIN
        IF NextBytesMatchString (Address, '<' + XMLField + '>') THEN
            BEGIN
            StartAddress := Address + Length (XMLField) + 2;  { Jump over the <field> entry }

            Address := StartAddress;  { Address of first character after field ID }

            IF StartAddress >= NumberCharsInUDPBuffer THEN Exit;

            WHILE Address < NumberCharsInUDPBuffer DO
                BEGIN
                IF NextBytesMatchString (Address, '</' + XMLField + '>') THEN
                    BEGIN
                    StopAddress := Address - 1;  { Address of last data character }

                    TempString := '';

                    IF StopAddress >= StartAddress THEN
                        FOR SaveAddress := StartAddress TO StopAddress DO
                            TempString := TempString + UDPBuffer [SaveAddress];

                    GetXMLData := TempString;
                    Exit;
                    END;

                Inc (Address);
                END;

            { We got to the end of the buffer without finding the </ entry }

            Exit;
            END;

        Inc (Address);
        END;
    END;



PROCEDURE N1MM_Object.Init;

VAR SocketAddr: TINetSockAddr;
    ConnectResult: INTEGER;
    FileWrite: TEXT;

    BEGIN
    NumberCharsinUDPBuffer := 0;

    UDP_PortNumber := N1MM_UDP_Port;

    { Setup the UDP port.  }

    UDP_Socket := fpSocket (AF_INET, SOCK_DGRAM, IPPROTO_UDP);

    SocketAddr.sin_family := AF_INET;
    SocketAddr.sin_port := htons (UDP_PortNumber);
    SocketAddr.sin_addr.s_addr := INADDR_ANY;

    ConnectResult := fpBind (UDP_Socket, @SocketAddr, SizeOf (SocketAddr));

    OpenFileForAppend (FileWrite, N1MM_DebugFileName);

    IF ConnectResult <> 0 THEN
        WriteLn (FileWrite, 'Unable to connect to UDP port ', UDP_PortNumber)
    ELSE
        WriteLn (FileWrite, 'Port ', UDP_PortNumber, ' open for input.  Socket = ',  UDP_Socket);

    Close (FileWrite);
    END;



FUNCTION N1MM_Object.Check_UDP_Port: BOOLEAN;

{ Returns true if a message was found.  The message will be in the UDPBuffer }

VAR Address, BytesRead: INTEGER;
    FDS: Tfdset;
    FileWrite: TEXT;

    BEGIN
    { Set up FDS and inquire if there is some data available }

    fpFd_zero (FDS);
    fpFd_set (UDP_Socket, FDS);
    fpSelect (UDP_Socket+1, @FDS, nil, nil, 0);

    IF fpFd_IsSet (UDP_Socket, FDS) = 0 THEN   { No data yet }
        BEGIN
        Check_UDP_Port := False;
        Exit;
        END;

    { We have some data to read - put it starting at char index 1 of message string }

    BytesRead := fpRecv (UDP_Socket, @UDPBuffer, UDPBufferSize, 0);

    IF BytesRead = -1 THEN
        BEGIN
        Check_UDP_Port := False;
        Exit;
        END;

    NumberCharsInUDPBuffer := BytesRead;

    OpenFileForAppend (FileWrite, N1MM_DebugFileName);
    WriteLn (FileWrite, GetTimeString, ' BytesRead = ', BytesRead);

    IF BytesRead > 0 THEN
        BEGIN
        FOR Address := 0 TO BytesRead - 1 DO
            Write (FileWrite, UDPBuffer [Address]);
        WriteLn (FileWrite);
        END;

    Close (FileWrite);
    Check_UDP_Port := True;
    END;



PROCEDURE N1MM_Object.Heartbeat;

{ This should be called as often as possible.  It will check to see if a UDP
  message has arrived and log it if so. }

    BEGIN
    IF Check_UDP_Port THEN LogContact;
    END;



PROCEDURE N1MM_Object.PutContactIntoLogFile (LogString: Str80);

VAR Time, QSONumber: INTEGER;
    Call, Exchange, LoggedCallsign: Str20;
    FileWrite: TEXT;

    BEGIN
    IF Copy (LogString, 1, 1) = ';' THEN  { Its a note - just copy it and be done }
        BEGIN
        WriteLogEntry (LogString);
        Exit;
        END;

    GetRidOfPostcedingSpaces (LogString);

    IF LogString <> '' THEN
        BEGIN
        IF LogString [LogEntryNameSentAddress] = '*' THEN
            Inc (TotalNamesSent);

        IF QSOTotals [All, Both] MOD ContactsPerPage = 0 THEN
            BEGIN
            IF QSOTotals [All, Both] > 0 THEN
                NextPage;
            PrintLogHeader;
            END;

        IF QSOTotals [All, Both] MOD ContactsPerPage > 9 THEN
            IF QSOTotals [All, Both] MOD 10 = 0 THEN
                WriteLogEntry ('');

        VisibleLog.PutLogEntryIntoSheet (LogString);
        WriteLogEntry                   (LogString);

        IF UnknownCountryFileEnable THEN
            BEGIN
            LoggedCallsign := GetLogEntryCall (LogString);
            IF CountryTable.GetCountry (LoggedCallsign, True) = -1 THEN
                IF OpenFileForAppend (FileWrite, UnknownCountryFileName) THEN
                    BEGIN
                    WriteLn (FileWrite, LogString);
                    Close (FileWrite);
                    END;
            END;

        { We only add QSOs to the pending list if we got QSO points for it }

        IF QTCsEnabled AND (MyContinent <> Europe) AND
           (GetLogEntryQSOPoints (LogString) > 0) THEN
               BEGIN
               Time := GetLogEntryIntegerTime (LogString);
               Call := GetLogEntryCall (LogString);
               Exchange := GetLogEntryExchangeString (LogString);
               GetRidOfPrecedingSpaces (Exchange);
               Exchange := PostcedingString (Exchange, ' ');
               GetRidOfPrecedingSpaces (Exchange);
               Exchange := PostcedingString (Exchange, ' ');
               GetRidOfPrecedingSpaces  (Exchange);
               GetRidOfPostcedingSpaces (Exchange);
               Val (Exchange, QSONumber);
               AddQSOToPendingQTCList (Time, Call, QSONumber);
               END;

        IF SingleBand <> All THEN
            BEGIN
            IF GetLogEntryBand (LogString) = SingleBand THEN
                TotalQSOPoints := TotalQSOPoints + GetLogEntryQSOPoints (LogString);
            END
        ELSE
            TotalQSOPoints := TotalQSOPoints + GetLogEntryQSOPoints (LogString);
        END;
    END;



PROCEDURE N1MM_Object.PushLogStringIntoEditableLogAndLogPopedQSO (LogString: Str80; MyQSO: BOOLEAN);

{ This is pretty much a copy of what is in tbsiq_subs.pas }

    BEGIN
    LogString := VisibleLog.PushLogEntry (LogString);

    { LogString is now what popped off the top of the editable window }

    GetRidOfPostcedingSpaces (LogString);

    IF LogString <> '' THEN
        PutContactIntoLogFile (LogString);  { AddQSOToSheets will process partial calls and exchange memory }

    END;



PROCEDURE N1MM_Object.LogN1MMContact (RXData: ContestExchange);

{ This procedure will log the contact just completed.  It will be
  pushed onto the editable log and the log entry popped off the editable
  log will be examined and written to the LOG.DAT file.

  This is just a minor scale down of the version found in tbsiq_subs.pas which is a
  scaled down version of the one found in logsubs2.pas.  It is left as an exercise to
  the student to see if the one in TBSIQ can just leverage this rountine.  Not much
  was removed from it.

  One possible trouble area here has to do with QSO numbers - but I can't worry too
  much about this at the moment }

VAR LogString: Str80;

    BEGIN
    CalculateQSOPoints (RXData);

    VisibleDupeSheetChanged := True;

    IF LastDeletedLogEntry <> '' THEN
        LastDeletedLogEntry := '';

    LastQSOLogged := RXData;

    IF TenMinuteRule <> NoTenMinuteRule THEN
        UpdateTenMinuteDate (RXData.Band, RXData.Mode);

    { This is simplified from LOGSUBS2 }

    IF VisibleLog.CallIsADupe (RXData.Callsign, RXData.Band, RXData.Mode) THEN
        RXData.QSOPoints := 0
    ELSE
        VisibleLog.ProcessMultipliers (RXData);  { This is in LOGEDIT.PAS }

    LogString := MakeLogString (RXData);  { This is in LOGSTUFF.PAS }

    IF (RXData.Band >= Band160) AND (RXData.Band <= Band10) THEN
        Inc (ContinentQSOCount [RXData.Band, RXData.QTH.Continent]);

    PushLogStringIntoEditableLogAndLogPopedQSO (LogString, True);

    IF DoingDomesticMults AND
       (MultByBand OR MultByMode) AND
       (RXData.DomesticQTH <> '') THEN
           VisibleLog.ShowDomesticMultiplierStatus (RXData.DomMultQTH);

    Inc (NumberContactsThisMinute);
    NumberQSOPointsThisMinute := NumberQSOPointsThisMinute + RXData.QSOPoints;

    IF FloppyFileSaveFrequency > 0 THEN
        IF QSOTotals [All, Both] > 0 THEN
            IF QSOTotals [All, Both] MOD FloppyFileSaveFrequency = 0 THEN
                SaveLogFileToFloppy;

    IF UpdateRestartFileEnable THEN Sheet.SaveRestartFile;

    UpdateTotals;
    DisplayTotalScore (TotalScore);
    VisibleLog.ShowRemainingMultipliers;

    IF BandMapEnable THEN
        BEGIN
        UpdateBandMapMultiplierStatus;
        UpdateBandMapDupeStatus (RXData.Callsign, RXData.Band, RXData.Mode, True);
        END;

    { This might not be a good thing to do.  FIrst off - Qsorder will not do anything
      useful as a result.  If I am sending this to yet anotehr computer - what if it
      is the one that sent the message.  Will it at some point send the QSO back to me? }

    IF (QSO_UDP_IP <> '') AND (QSO_UDP_Port <> 0) THEN
        BEGIN
        RXData.Date := GetFullDateString;
        SendQSOToUDPPort (RXData);
        END;
    END;



PROCEDURE N1MM_Object.GetCallFromUDPMessage (VAR RXData: ContestExchange);

    BEGIN
    RXData.Callsign := GetXMLData ('call');
    RXData.DXQTH := GetXMLData ('countryprefix');
    END;


PROCEDURE N1MM_Object.GetTimeAndDateFromUDPMessage (VAR RXData: ContestExchange);

VAR TempString: STRING;
    UDPDateString, UDPTimeString: Str20;
    YearString, MonthString, DayString: Str20;
    SecondsString: Str20;

    BEGIN
    TempString := GetXMLData ('timestamp');

    UDPDateString := RemoveFirstString (TempString);   { 2020-01-17 }
    UDPTimeString := RemoveFirstString (TempString);   { 16:43:38 }

    { Only use two digits of the year }

    YearString := Copy (UDPDateString, 3, 2);

    { Convert integer month into JAN - DEC }

    MonthString := Copy (UDPDateString, 6, 2);

    IF MonthString = '01' THEN MonthString := 'JAN' ELSE
    IF MonthString = '02' THEN MonthString := 'FEB' ELSE
    IF MonthString = '03' THEN MonthString := 'MAR' ELSE
    IF MonthString = '04' THEN MonthString := 'APR' ELSE
    IF MonthString = '05' THEN MonthString := 'MAY' ELSE
    IF MonthString = '06' THEN MonthString := 'JUN' ELSE
    IF MonthString = '07' THEN MonthString := 'JUL' ELSE
    IF MonthString = '08' THEN MonthString := 'AUG' ELSE
    IF MonthString = '09' THEN MonthString := 'SEP' ELSE
    IF MonthString = '10' THEN MonthString := 'OCT' ELSE
    IF MonthString = '11' THEN MonthString := 'NOV' ELSE
    IF MonthString = '12' THEN MonthString := 'DEC' ELSE
        MonthString := '???';

    DayString := Copy (UDPDateString, 9, 2);

    RXData.Date := DayString + '-' + MonthString + '-' + YearString;

    { Now we deal with the time - we have 12:34:56 and need an integer value for the
      hour/minutes and seconds in its own field as an integer }

    SecondsString := Copy (UDPTimeString, Length (UDPTimeString) - 1, 2);

    Val (SecondsString, RXData.TimeSeconds);

    { Remove seconds and the last colon }

    Delete (UDPTimeString, Length (UDPTimeString) - 2, 3);

    { Get rid of the remaining colon }

    Delete (UDPTimeString, Length (UDPTimeString) - 2 , 1);

    Val (UDPTimeString, RXData.Time);
    END;



PROCEDURE N1MM_Object.GetBandAndModeFromUDPMessage (VAR RXData: ContestExchange);

{ <band>3.5</band>  and  <mode>CW</mode> }

VAR BandString, ModeString: Str20;

    BEGIN
    BandString := GetXMLData ('band');
    ModeString := GetXMLData ('mode');

    RXData.Band := NoBand;
    RXData.Mode := NoMode;

    IF BandString = '1.8' THEN RXData.Band := Band160 ELSE
    IF BandString = '3.5' THEN RXData.Band := Band80 ELSE
    IF BandString = '7' THEN RXData.Band := Band40 ELSE
    IF BandString = '10' THEN RXData.Band := Band30 ELSE
    IF BandString = '14' THEN RXData.Band := Band20 ELSE
    IF BandString = '18' THEN RXData.Band := Band17 ELSE
    IF BandString = '21' THEN RXData.Band := Band15 ELSE
    IF BandString = '24' THEN RXData.Band := Band12 ELSE
    IF BandString = '28' THEN RXData.Band := Band10 ELSE
    IF BandString = '50' THEN RXData.Band := Band6 ELSE
    IF BandString = '144' THEN RXData.Band := Band2 ELSE
    IF BandString = '222' THEN RXData.Band := Band222 ELSE
    IF BandString = '420' THEN RXData.Band := Band432 ELSE
    IF BandString = '902' THEN RXData.Band := Band902 ELSE
    IF BandString = '1240' THEN RXData.Band := Band1296 ELSE
    IF BandString = '2300' THEN RXData.Band := Band2304 ELSE
    IF BandString = '3300' THEN RXData.Band := Band3456 ELSE
    IF BandString = '5050' THEN RXData.Band := Band5760 ELSE
    IF BandString = '10000' THEN RXData.Band := Band10G ELSE
    IF BandString = '24000' THEN RXData.Band := Band24G;

    IF ModeString = 'CW' THEN RXData.Mode := CW ELSE
    IF ModeString = 'SSB' THEN RXData.Mode := Phone;
    IF ModeString = 'USB' THEN RXData.Mode := Phone;
    IF ModeString = 'LSB' THEN RXData.Mode := Phone;

    IF (ModeString = 'DIG') OR (ModeString = 'RTTY') OR (ModeString = 'FSK') THEN
        RXData.Mode := Digital;

    END;



PROCEDURE N1MM_Object.GetExchangeDataFromUDPMessage (VAR RXData: ContestExchange);

VAR TempString: STRING;
    xResult, Number: INTEGER;

    BEGIN
    { Exchagne stuff that we will have for every kind of QSO }

    RXData.RSTSent := GetXMLData ('snt');
    RXData.RSTReceived := GetXMLData ('rcv');

    TempString := GetXMLData ('sntnr');
    Val (TempString, Number, xResult);
    IF xResult = 0 THEN RXData.NumberSent := Number;

    TempString := GetXMLData ('rcvnr');
    Val (TempString, Number, xResult);
    IF xResult = 0 THEN RXData.NumberReceived:= Number;

    { Now look at the ActiveExchange and pull out the appropriate data }

    CASE ActiveExchange OF
        UnknownExchange: BEGIN END;
        NoExchangeReceived: BEGIN END;
        CheckAndChapterOrQTHExchange: BEGIN END;
        ClassDomesticOrDXQTHExchange: BEGIN END;
        CWTExchange: BEGIN END;
        KidsDayExchange: BEGIN END;
        NameAndDomesticOrDXQTHExchange: BEGIN END;
        NameQTHAndPossibleTenTenNumber: BEGIN END;
        NameAndPossibleGridSquareExchange: BEGIN END;
        NZFieldDayExchange: BEGIN END;
        QSONumberAndNameExchange: BEGIN END;
        QSONumberDomesticOrDXQTHExchange: BEGIN END;
        QSONumberDomesticQTHExchange: BEGIN END;
        QSONumberNameChapterAndQTHExchange: BEGIN END;
        QSONumberNameDomesticOrDXQTHExchange: BEGIN END;

        QSONumberPrecedenceCheckDomesticQTHExchange:  { AKA Sweepstakes }
            BEGIN
            RXData.Precedence := GetXMLData ('prec');
            RXData.Check := GetXMLData ('ck');
            RXData.QTHString := GetXMLData ('section');
            END;

        RSTAgeExchange: BEGIN END;
        RSTALLJAPrefectureAndPrecedenceExchange: BEGIN END;
        RSTAndContinentExchange: BEGIN END;
        RSTAndDomesticQTHOrZoneExchange: BEGIN END;

        RSTAndGridExchange, RSTAndOrGridExchange:
            BEGIN
            RXData.DomesticQTH := GetXMLData ('gridsquare');
            RXData.QTHString := RXData.DomesticQTH;
            END;

        RSTAndQSONumberOrDomesticQTHExchange: BEGIN END;
        RSTAndPostalCodeExchange: BEGIN END;
        RSTDomesticOrDXQTHExchange: BEGIN END;
        RSTDomesticQTHExchange: BEGIN END;
        RSTDomesticQTHOrQSONumberExchange: BEGIN END;
        RSTNameAndQTHExchange: BEGIN END;
        RSTPossibleDomesticQTHAndPower: BEGIN END;

        RSTPowerExchange:
            RXData.Power := GetXMLData ('power');

        RSTPrefectureExchange: BEGIN END;
        RSTQSONumberAndDomesticQTHExchange: BEGIN END;
        RSTQSONumberAndGridSquareExchange: BEGIN END;
        RSTQSONumberAndPossibleDomesticQTHExchange: BEGIN END;
        QSONumberAndPossibleDomesticQTHExchange: BEGIN END; {KK1L: 6.73 For MIQP originally}
        RSTQSONumberAndRandomCharactersExchange: BEGIN END;
        RSTQTHNameAndFistsNumberOrPowerExchange: BEGIN END;

        RSTQSONumberExchange: BEGIN END;  { Already taken care of }
        RSTQTHExchange: BEGIN END;
        RSTZoneAndPossibleDomesticQTHExchange: BEGIN END;

        RSTZoneExchange:
            RXData.Zone := GetXMLData ('zone');

        RSTZoneOrSocietyExchange: { Not sure where N1MM puts society }
            BEGIN
            END;

        RSTLongJAPrefectureExchange: BEGIN END;
        END;  { of CASE ActiveExchange }
    END;



PROCEDURE N1MM_Object.GetFrequencyFromUDPMessage (VAR RXData: ContestExchange);

{ Frequency is in 10's of hertz }

VAR TempString: Str20;
    TempFreq: LONGINT;
    xResult: INTEGER;

    BEGIN
    TempString := GetXMLData ('rxfreq');
    Val (TempString, TempFreq, xResult);

    IF xResult = 0 THEN
        RXData.Frequency := TempFreq * 10;
    END;



FUNCTION N1MM_Object.CreateRXDataFromUDPMessage (VAR RXData: ContestExchange): BOOLEAN;

{ Does the reverse of the MergeRXExchangeToUDPRecord so that we can take a QSO UDP message
  from like N1MM and log it in the TRLog program.  I put this here instead of N1MM so that
  other "people" could use it - and also all of the field definitions are located here for
  reference.  I will do some amount of checking to make sure the data looks complete and
  if so - return TRUE. }

    BEGIN
    CreateRXDataFromUDPMessage := False;
    ClearContestExchange (RXData);

    GetBandAndModeFromUDPMessage  (RXData);
    GetFrequencyFromUDPMessage    (RXData);
    GetTimeAndDateFromUDPMessage  (RXData);
    GetCallFromUDPMessage         (RXData);
    GetExchangeDataFromUDPMessage (RXData);
    END;



PROCEDURE N1MM_Object.LogContact;

{ This is the meat of the N1MM interface.  Any UDP messages will be in the QTC Buffer
  wull be parsed into a TR Log RXData record and then the normal TR Log loggin routines
  will take that record - parse it into a Log String and push it into the editable
  log window. }

VAR RXData: ContestExchange;

    BEGIN
    CreateRXDataFromUDPMessage (RXData);
    LogN1MMContact (RXData);
    END;



    BEGIN
    N1MM_UDP_Port := 0;    { Declared in logwind.pas }
    END.
