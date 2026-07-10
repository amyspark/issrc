unit Compression.LZ4;

{
  SPDX-FileCopyrightText: 2026 Amyspark <amy@amyspark.me>
  SPDX-License-Identifier: MPL-2.0
  Declarations for LZ4 functions & structures
}

{$T+}

interface

uses
  Windows, SysUtils, Compression.Base;

function LZ4InitCompressFunctions(Module: HMODULE): Boolean;
function LZ4InitDecompressFunctions(Module: HMODULE): Boolean;
function LZ4GetLevel(const Value: String; var Level: Integer): Boolean;

const
  clLZ4Fast = 2;
  clLZ4Normal = 9;
  clLZ4Max = 10;
  clLZ4Ultra = 12;

type
  TLZ4Error = UInt64;
  TLZ4CompressionContext = Pointer;
  TLZ4DecompressionContext = Pointer;

  TLZ4FrameInfo = record
    blockSizeID: Cardinal;         { max64KB, max256KB, max1MB, max4MB; 0 == default (LZ4F_max64KB) }
    blockMode: Cardinal;           { LZ4F_blockLinked, LZ4F_blockIndependent; 0 == default (LZ4F_blockLinked) }
    contentChecksumFlag: Cardinal; { 1: add a 32-bit checksum of frame's decompressed data; 0 == default (disabled) }
    frameType: Cardinal;           { read-only field : LZ4F_frame or LZ4F_skippableFrame }
    contentSize: UInt64;           { Size of uncompressed content ; 0 == unknown }
    dictID: Cardinal;              { Dictionary ID, sent by compressor to help decoder select correct dictionary; 0 == no dictID provided }
    blockChecksumFlag: Cardinal;   { 1: each block followed by a checksum of block's compressed data; 0 == default (disabled) }
  end;

  TLZ4Preferences = record
    frameInfo: TLZ4FrameInfo;
    compressionLevel: Integer;                 { 0: default (fast mode); values > LZ4HC_CLEVEL_MAX count as LZ4HC_CLEVEL_MAX; values < 0 trigger "fast acceleration" }
    autoFlush: Cardinal;                       { 1: always flush; reduces usage of internal buffers }
    favorDecSpeed: Cardinal;                   { 1: parser favors decompression speed vs compression ratio. Only works for high compression modes (>= LZ4HC_CLEVEL_OPT_MIN) }
    reserved: Array[0..2] of Cardinal;         { must be zero for forward compatibility }
  end;

  TLZ4Compressor = class(TCustomCompressor)
  private
    FCompressionLevel: Integer;
    FInitialized: Boolean;
    FPrefs: TLZ4Preferences;
    FStrm: TLZ4CompressionContext;
    { Query LZ4F_compressBound with input size, TLZ4Preferences defaults }
    FBuffer: array[0..8 * 1024 * 1024] of Byte;
    FNextOut: ^Byte;
    FAvailOut: UInt64; { Sum this to FBuffer }
    FTotalOut: UInt64;
    procedure EndCompress;
    procedure FlushBuffer;
    procedure InitCompress;
  protected
    procedure DoCompress(const Buffer; Count: Cardinal); override;
    procedure DoFinish; override;
  public
    constructor Create(AWriteProc: TCompressorWriteProc;
      AProgressProc: TCompressorProgressProc; CompressionLevel: Integer;
      ACompressorProps: TCompressorProps); override;
    destructor Destroy; override;
  end;

  TLZ4Decompressor = class(TCustomDecompressor)
  private
    FInitialized: Boolean;
    FStrm: TLZ4DecompressionContext;
    { Query LZ4F_compressBound with input size, TLZ4Preferences defaults }
    { Block size 4MB -> 4194312B per block approx. }
    FBuffer: array[0..4 * 1024 * 1024 + 8] of Byte;
    FReachedEnd: Boolean;
    FNextIn: ^Byte;
    FAvailIn: UInt64;
    FTotalIn: UInt64;
  public
    constructor Create(AReadProc: TDecompressorReadProc); override;
    destructor Destroy; override;
    procedure DecompressInto(var Buffer; Count: Cardinal); override;
    procedure Reset; override;
  end;

implementation

const
  SZlibDataError = 'LZ4: Compressed data is corrupted';
  SInternalError = 'LZ4: Internal error: Code %d -- %s';
  LZ4F_VERSION = 100;  { Do not change this! }

var
  LZ4F_createCompressionContext: function(out cctx: TLZ4CompressionContext; version: Cardinal): TLZ4Error; stdcall;
  LZ4F_compressBegin: function(cctx: TLZ4CompressionContext; dstBuffer: Pointer; dstCapacity: UInt64; var prefsPtr: TLZ4Preferences): UInt64; stdcall;
  LZ4F_compressUpdate: function(cctx: TLZ4CompressionContext; dstBuffer: Pointer; dstCapacity: UInt64; srcBuffer: Pointer; srcSize: UInt64; cOptPtr: Pointer): UInt64; stdcall;
  LZ4F_flush: function(cctx: TLZ4CompressionContext; dstBuffer: Pointer; dstCapacity: UInt64; cOptPtr: Pointer): UInt64; stdcall;
  LZ4F_compressEnd: function(cctx: TLZ4CompressionContext; dstBuffer: Pointer; dstCapacity: UInt64; cOptPtr: Pointer): UInt64; stdcall;
  LZ4F_freeCompressionContext: function(cctx: TLZ4CompressionContext): TLZ4Error; stdcall;

  LZ4F_createDecompressionContext: function(out dctx: TLZ4DecompressionContext; version: Cardinal): TLZ4Error; stdcall;
  LZ4F_decompress: function(dctx: TLZ4DecompressionContext; dstBuffer: Pointer; var dstSizePtr: UInt64; srcBuffer: Pointer; var srcSizePtr: UInt64; dOptPtr: Pointer): UInt64; stdcall;
  LZ4F_resetDecompressionContext: procedure(dctx: TLZ4DecompressionContext); stdcall;
  LZ4F_freeDecompressionContext: function(dctx: TLZ4DecompressionContext): TLZ4Error; stdcall;

  LZ4F_isError: function(code: UInt64): Cardinal; stdcall;
  LZ4F_getErrorName: function(code: UInt64): PAnsiChar; stdcall;

function LZ4InitCompressFunctions(Module: HMODULE): Boolean;
begin
  LZ4F_createCompressionContext := GetProcAddress(Module, 'LZ4F_createCompressionContext');
  LZ4F_compressBegin := GetProcAddress(Module, 'LZ4F_compressBegin');
  LZ4F_compressUpdate := GetProcAddress(Module, 'LZ4F_compressUpdate');
  LZ4F_flush := GetProcAddress(Module, 'LZ4F_flush');
  LZ4F_compressEnd := GetProcAddress(Module, 'LZ4F_compressEnd');
  LZ4F_freeCompressionContext := GetProcAddress(Module, 'LZ4F_freeCompressionContext');
  LZ4F_isError := GetProcAddress(Module, 'LZ4F_isError');
  LZ4F_getErrorName := GetProcAddress(Module, 'LZ4F_getErrorName');
  Result := Assigned(LZ4F_createCompressionContext) and Assigned(LZ4F_compressBegin) and
    Assigned(LZ4F_compressUpdate) and
    Assigned(LZ4F_flush) and
    Assigned(LZ4F_compressEnd) and
    Assigned(LZ4F_freeCompressionContext) and
    Assigned(LZ4F_isError) and
    Assigned(LZ4F_getErrorName);
  if not Result then begin
    LZ4F_createCompressionContext := nil;
    LZ4F_compressBegin := nil;
    LZ4F_compressUpdate := nil;
    LZ4F_flush := nil;
    LZ4F_compressEnd := nil;
    LZ4F_freeCompressionContext := nil;
    LZ4F_isError := nil;
    LZ4F_getErrorName := nil;
  end;
end;

function LZ4InitDecompressFunctions(Module: HMODULE): Boolean;
begin
  LZ4F_createDecompressionContext := GetProcAddress(Module, 'LZ4F_createDecompressionContext');
  LZ4F_decompress := GetProcAddress(Module, 'LZ4F_decompress');
  LZ4F_resetDecompressionContext := GetProcAddress(Module, 'LZ4F_resetDecompressionContext');
  LZ4F_freeDecompressionContext := GetProcAddress(Module, 'LZ4F_freeDecompressionContext');
  LZ4F_isError := GetProcAddress(Module, 'LZ4F_isError');
  LZ4F_getErrorName := GetProcAddress(Module, 'LZ4F_getErrorName');
  Result := Assigned(LZ4F_createDecompressionContext) and Assigned(LZ4F_decompress) and
    Assigned(LZ4F_resetDecompressionContext) and
    Assigned(LZ4F_freeDecompressionContext) and
    Assigned(LZ4F_isError) and
    Assigned(LZ4F_getErrorName);
  if not Result then begin
    LZ4F_createDecompressionContext := nil;
    LZ4F_decompress := nil;
    LZ4F_resetDecompressionContext := nil;
    LZ4F_freeDecompressionContext := nil;
    LZ4F_isError := nil;
    LZ4F_getErrorName := nil;
  end;
end;

procedure Check(const Code: UInt64);
begin
  if LZ4F_isError(Code) = 0 then
    Exit;
  raise ECompressInternalError.CreateFmt(SInternalError, [Code, LZ4F_getErrorName(Code)]);
end;

procedure InitCompressionPrefs(var prefs: TLZ4Preferences; cLevel: Integer);
begin
  FillChar(prefs, SizeOf(prefs), 0);
  with prefs do begin
    frameInfo.blockSizeID := 7; { 4MB -> 4194312B}
    compressionLevel := cLevel;
    autoFlush := 1;
    favorDecSpeed := 1;
  end;
end;

function LZ4GetLevel(const Value: String; var Level: Integer): Boolean;
begin
  Result := True;
  if CompareText(Value, 'fast') = 0 then
    Level := clLZ4Fast
  else if CompareText(Value, 'normal') = 0 then
    Level := clLZ4Normal
  else if CompareText(Value, 'max') = 0 then
    Level := clLZ4Max
  else if CompareText(Value, 'ultra') = 0 then
    Level := clLZ4Ultra
  else
    Result := False;
end;

{ TLZ4Compressor }

constructor TLZ4Compressor.Create(AWriteProc: TCompressorWriteProc;
  AProgressProc: TCompressorProgressProc; CompressionLevel: Integer;
  ACompressorProps: TCompressorProps);
begin
  inherited;
  FCompressionLevel := CompressionLevel;
  InitCompressionPrefs(FPrefs, FCompressionLevel);
  Check(LZ4F_createCompressionContext(FStrm, LZ4F_VERSION));
  InitCompress;
end;

destructor TLZ4Compressor.Destroy;
begin
  LZ4F_freeCompressionContext(FStrm);
  inherited;
end;

procedure TLZ4Compressor.InitCompress;
var
  Code: UInt64;
begin
  if not FInitialized then begin
    Code := LZ4F_compressBegin(FStrm, @FBuffer[0], SizeOf(FBuffer), FPrefs);
    if LZ4F_isError(Code) <> 0 then
      raise ECompressDataError.CreateFmt(SInternalError, [Code, LZ4F_getErrorName(Code)]);
    FNextOut := @FBuffer[0];
    Inc(FNextOut, Code);
    FAvailOut := SizeOf(FBuffer) - Code;
    FTotalOut := Code;
    FInitialized := True;
  end;
end;

procedure TLZ4Compressor.EndCompress;
begin
  if FInitialized then begin
    FInitialized := False;
  end;
end;

procedure TLZ4Compressor.FlushBuffer;
begin
  if FTotalOut <> 0 then begin
    WriteProc(FBuffer, Cardinal(FTotalOut));
    FNextOut := @FBuffer[0];
    FAvailOut := SizeOf(FBuffer);
    FTotalOut := 0;
  end;
end;

procedure TLZ4Compressor.DoCompress(const Buffer; Count: Cardinal);
var
  Code: TLZ4Error;
begin
  InitCompress;
  Code := LZ4F_compressUpdate(FStrm, FNextOut, FAvailOut, @Buffer, Count, nil);
  if LZ4F_isError(Code) <> 0 then
    raise ECompressDataError.CreateFmt(SInternalError, [Code, LZ4F_getErrorName(Code)]);
  if Code <> 0 then begin
    FTotalOut := FTotalOut + Code;
    FlushBuffer;
  end;
  if Assigned(ProgressProc) then
    ProgressProc(Count);
end;

procedure TLZ4Compressor.DoFinish;
var
  code: UInt64;
begin
  InitCompress;
  Code := LZ4F_compressEnd(FStrm, FNextOut, FAvailOut, nil);
  if LZ4F_isError(Code) <> 0 then
    raise ECompressDataError.CreateFmt(SInternalError, [Code, LZ4F_getErrorName(Code)]);
  { Do not update FNextOut or FAvailOut; we are done }
  FTotalOut := FTotalOut + Code;
  FlushBuffer;
  EndCompress;
end;

{ TLZ4Decompressor }

constructor TLZ4Decompressor.Create(AReadProc: TDecompressorReadProc);
var
  code: UInt64;
begin
  inherited Create(AReadProc);
  code := LZ4F_createDecompressionContext(FStrm, LZ4F_VERSION);
  if code <> 0 then
    raise ECompressDataError.CreateFmt(SInternalError, [Code, LZ4F_getErrorName(Code)]);
  FNextIn := @FBuffer[0];
  FAvailIn := 0;
  FTotalIn := 0;
  FInitialized := True;
end;

destructor TLZ4Decompressor.Destroy;
begin
  if FInitialized then begin
    LZ4F_freeDecompressionContext(FStrm);
    FStrm := nil;
  end;
  inherited Destroy;
end;

procedure TLZ4Decompressor.DecompressInto(var Buffer; Count: Cardinal);
var
  code: UInt64;
  next_out: ^Byte;
  avail_out: UInt64;
  total_out: UInt64;
begin
  next_out := @Buffer;
  avail_out := Count;
  total_out := 0;

  while not FReachedEnd do begin
    if FAvailIn = 0 then begin
      FNextIn := @FBuffer[0];
      FAvailIn := ReadProc(FBuffer, SizeOf(FBuffer));
      FTotalIn := 0;
    end;

    if FAvailIn = 0 then begin
      FReachedEnd := True;
      break;
    end;

    code := LZ4F_decompress(FStrm, next_out, avail_out, FNextIn, FAvailIn, nil);

    if LZ4F_isError(code) <> 0 then
      raise ECompressDataError.CreateFmt(SInternalError, [code, LZ4F_getErrorName(code)]);

    FTotalIn := FTotalIn + FAvailIn;
    FNextIn := @FBuffer[FTotalIn]; { advance the pointer by the consumed input }
    FAvailIn := SizeOf(FBuffer) - FTotalIn;
    total_out := total_out + avail_out;
    next_out := @Buffer;
    Inc(next_out, total_out); { advance the pointer by the inflated data }
    avail_out := Count - total_out;

    if (code = 0) and (avail_out = 0) then
      FReachedEnd := True;
  end;
end;

procedure TLZ4Decompressor.Reset;
begin
  LZ4F_resetDecompressionContext(FStrm);
  FReachedEnd := False;
  FNextIn := @FBuffer[0];
  FAvailIn := 0;
  FTotalIn := 0;
end;

end.
