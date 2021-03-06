unit NV12;

{$mode objfpc}{$H+}
{$CODEPAGE UTF-8}

interface

uses
  AviUtl, Parallel;

procedure DrawFrameYC48(const Dest: Pointer; const W, H, DLine, BorderWidth: integer;
  const Color: TPixelYC); inline;
procedure CopyYC48(const Parallel: TParallel; Dest, Src: Pointer;
  const W, H, SLine, DLine: integer); inline;
procedure CalcDownScaledSize(var W, H: integer; const Factor: integer); inline;
procedure DownScaleYC48(const Parallel: TParallel; const Dest, Src: Pointer;
  var W, H: integer; const SLine: integer; const Factor: integer); inline;
procedure UpScaleYC48(const Parallel: TParallel; const Dest, Src: Pointer;
  const OrigW, OrigH: integer; const DLine: integer; const Factor: integer); inline;
function EncodeYC48ToNV12(const Parallel: TParallel; const Dest, Src: Pointer;
  const W, H: integer; const SLine: integer): integer; inline;
procedure DecodeNV12ToYC48(const Parallel: TParallel; const Dest, Src: Pointer;
  const W, H: integer; const DLine: integer); inline;

implementation

uses
  Math;

procedure DrawFrameYC48(const Dest: Pointer; const W, H, DLine, BorderWidth: integer;
  const Color: TPixelYC); inline;
var
  X, Y: integer;
  D1, D2: Pointer;
begin
  D1 := Dest;
  D2 := Dest + (H - BorderWidth) * DLine;
  for X := 0 to W - 1 do
  begin
    PPixelYC(D1)^ := Color;
    PPixelYC(D2)^ := Color;
    Inc(D1, SizeOf(TPixelYC));
    Inc(D2, SizeOf(TPixelYC));
  end;
  Dec(D1, W * SizeOf(TPixelYC));
  Dec(D2, W * SizeOf(TPixelYC));
  for Y := 1 to BorderWidth - 1 do
  begin
    Move(D1^, (D1 + Y * DLine)^, W * SizeOf(TPixelYC));
    Move(D2^, (D2 + Y * DLine)^, W * SizeOf(TPixelYC));
  end;

  Inc(D1, (BorderWidth - 1) * DLine);
  D2 := D1 + (W - BorderWidth) * SizeOf(TPixelYC);
  for Y := 1 to H - BorderWidth * 2 do
  begin
    Move(D1^, (D1 + Y * DLine)^, BorderWidth * SizeOf(TPixelYC));
    Move(D2^, (D2 + Y * DLine)^, BorderWidth * SizeOf(TPixelYC));
  end;
end;

type
  TCopyYC48Params = record
    S, D: PByte;
    Width, SLine, DLine: integer;
  end;
  PCopyYC48Params = ^TCopyYC48Params;

procedure CopyYC48ParallelInner(const Index, N: integer; const UserData: Pointer);
var
  Params: PCopyYC48Params absolute UserData;
  Y, Width, SLine, DLine: integer;
  S, D: PByte;
begin
  Width := Params^.Width;
  SLine := Params^.SLine;
  DLine := Params^.DLine;
  S := Params^.S;
  D := Params^.D;
  Inc(S, SLine * Index);
  Inc(D, DLine * Index);
  for Y := 0 to N - 1 do
  begin
    Move(S^, D^, Width);
    Inc(S, SLine);
    Inc(D, DLine);
  end;
end;

procedure CopyYC48(const Parallel: TParallel; Dest, Src: Pointer;
  const W, H, SLine, DLine: integer); inline;
var
  Params: TCopyYC48Params;
begin
  Params.D := Dest;
  Params.S := Src;
  Params.Width := W * SizeOf(TPixelYC);
  Params.SLine := SLine;
  Params.DLine := DLine;
  Parallel.Execute(@CopyYC48ParallelInner, @Params, 0, H);
end;

procedure CalcDownScaledSize(var W, H: integer; const Factor: integer); inline;
begin
  W := (W + Factor - 1) div Factor;
  H := (H + Factor - 1) div Factor;
end;

type
  TDownScaleYC48Params = record
    Dest, Src: Pointer;
    Width, SLine, Factor: integer;
  end;
  PDownScaleYC48Params = ^TDownScaleYC48Params;

procedure DownScaleYC48Inner(const Index, N: integer; const UserData: Pointer);
var
  Params: PDownScaleYC48Params absolute UserData;
  X, Y, Width, SLine, Factor: integer;
  Src: Pointer;
  S, D: PPixelYC;
begin
  Factor := Params^.Factor;
  SLine := Params^.SLine;
  Width := Params^.Width;
  Src := Params^.Src;
  D := Params^.Dest;
  Inc(Src, Index * SLine);
  Inc(D, Index * Width);
  for Y := 0 to N - 1 do
  begin
    S := PPixelYC(Src);
    for X := 0 to Width - 1 do
    begin
      D^ := S^;
      Inc(D);
      Inc(S, Factor);
    end;
    Inc(Src, SLine);
  end;
end;

procedure DownScaleYC48(const Parallel: TParallel; const Dest, Src: Pointer;
  var W, H: integer; const SLine: integer; const Factor: integer); inline;
var
  Params: TDownScaleYC48Params;
begin
  CalcDownScaledSize(W, H, Factor);
  Params.Dest := Dest;
  Params.Src := Src;
  Params.Factor := Factor;
  Params.SLine := SLine * Factor;
  Params.Width := W;
  // Parallelization overhead is too big, currently disabled.
  DownScaleYC48Inner(0, H, @Params);
  // Parallel.Execute(@DownScaleYC48Inner, @Params, 0, H);
end;

type
  TUpScaleYC48Params = record
    Dest, Src: Pointer;
    OrigW, OrigH: integer;
    DLine, Factor: integer
  end;
  PUpScaleYC48Params = ^TUpScaleYC48Params;

procedure UpScaleYC48Inner(const Index, N: integer; const UserData: Pointer);
var
  Params: PUpScaleYC48Params absolute UserData;
  SW, SH, FW, FH, X, Y, I, OrigW, OrigLine, DLine, Factor: integer;
  Pix: TPixelYC;
  S, D: PPixelYC;
  Dest: Pointer;
begin
  Factor := Params^.Factor;
  OrigW := Params^.OrigW;
  FW := OrigW div Factor;
  FH := Params^.OrigH div Factor;
  SW := (OrigW + Factor - 1) div Factor;
  SH := (Params^.OrigH + Factor - 1) div Factor;
  OrigLine := OrigW * SizeOf(TPixelYC);
  DLine := Params^.DLine;
  S := Params^.Src;
  Dest := Params^.Dest;
  Inc(S, Index * SW);
  Inc(Dest, Index * DLine * Factor);
  for Y := 0 to N - 1 do
  begin
    D := PPixelYC(Dest);
    for X := 0 to FW - 1 do
    begin
      Pix := S^;
      for I := 0 to Factor - 1 do
      begin
        D^ := Pix;
        Inc(D);
      end;
      Inc(S);
    end;
    if SW <> FW then
    begin
      Pix := S^;
      for X := FW * Factor to OrigW - 1 do
      begin
        D^ := Pix;
        Inc(D);
      end;
      Inc(S);
    end;
    for I := 1 to Factor - 1 do
    begin
      Move(Dest^, (Dest + DLine * I)^, OrigLine);
    end;
    Inc(Dest, DLine * Factor);
  end;
  if (Index + N = FH) and (SH <> FH) then
  begin
    D := PPixelYC(Dest);
    for X := 0 to FW - 1 do
    begin
      Pix := S^;
      for I := 0 to Factor - 1 do
      begin
        D^ := Pix;
        Inc(D);
      end;
      Inc(S);
    end;
    if SW <> FW then
    begin
      Pix := S^;
      for X := FW * Factor to OrigW - 1 do
      begin
        D^ := Pix;
        Inc(D);
      end;
      Inc(S);
    end;
    for Y := FH * Factor to Params^.OrigH - 1 do
    begin
      Move(Dest^, (Dest + DLine)^, OrigLine);
      Inc(Dest, DLine);
    end;
  end;
end;

procedure UpScaleYC48(const Parallel: TParallel; const Dest, Src: Pointer;
  const OrigW, OrigH: integer; const DLine: integer; const Factor: integer); inline;
var
  Params: TUpScaleYC48Params;
begin
  Params.Dest := Dest;
  Params.Src := Src;
  Params.Factor := Factor;
  Params.OrigW := OrigW;
  Params.OrigH := OrigH;
  Params.DLine := DLine;
  Parallel.Execute(@UpScaleYC48Inner, @Params, 0, OrigH div Factor);
end;

// Reference: https://makiuchi-d.github.io/mksoft/doc/aviutlyc.html

type
  TUV = record
    U, V: byte;
  end;
  PUV = ^TUV;

  TEncodeYC48ToNV12Params = record
    Dest, Src: Pointer;
    W, H: integer;
    SLine: integer;
  end;
  PEncodeYC48ToNV12Params = ^TEncodeYC48ToNV12Params;

procedure EncodeYC48ToNV12Inner(const Index, N: integer; const UserData: Pointer);
var
  Params: PEncodeYC48ToNV12Params absolute UserData;
  SLine, DLine, X, Y, YWB, YHB, UVW, UVH: integer;
  S1, S2: PPixelYC;
  S, DY1, DY2: PByte;
  DUV: PUV;
begin
  YWB := Params^.W div 2;
  YHB := Params^.H div 2;
  UVW := (Params^.W + 2 - 1) div 2;
  UVH := (Params^.H + 2 - 1) div 2;
  SLine := Params^.SLine;
  S := Params^.Src + Index * SLine * 2;
  DLine := Params^.W;
  DY1 := Params^.Dest + Index * DLine * 2;
  DY2 := DY1 + DLine;
  DUV := PUV(Params^.Dest + Params^.W * Params^.H) + Index * UVW;

  for Y := 0 to N - 1 do
  begin
    S1 := PPixelYC(S);
    S2 := PPixelYC(S + SLine);
    for X := 0 to YWB - 1 do
    begin
      DUV^.U := (((EnsureRange(S1^.Cb, -2048, 2048) + 2048) * 7 + 66) shr 7) + 16;
      DUV^.V := (((EnsureRange(S1^.Cr, -2048, 2048) + 2048) * 7 + 66) shr 7) + 16;
      (DY1 + 0)^ := ((EnsureRange((S1 + 0)^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      (DY1 + 1)^ := ((EnsureRange((S1 + 1)^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      (DY2 + 0)^ := ((EnsureRange((S2 + 0)^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      (DY2 + 1)^ := ((EnsureRange((S2 + 1)^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      Inc(DY1, 2);
      Inc(DY2, 2);
      Inc(S1, 2);
      Inc(S2, 2);
      Inc(DUV);
    end;
    if YWB <> UVW then
    begin
      DUV^.U := (((EnsureRange(S1^.Cb, -2048, 2048) + 2048) * 7 + 66) shr 7) + 16;
      DUV^.V := (((EnsureRange(S1^.Cr, -2048, 2048) + 2048) * 7 + 66) shr 7) + 16;
      //for X := YWB * 2 to W - 1 do
      //begin
      DY1^ := ((EnsureRange(S1^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      DY2^ := ((EnsureRange(S2^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      Inc(DY1);
      Inc(DY2);
      Inc(S1);
      Inc(S2);
      //end;
      Inc(DUV);
    end;
    Inc(S, SLine * 2);
    Inc(DY1, DLine);
    Inc(DY2, DLine);
  end;
  if (Index + N = YHB) and (YHB <> UVH) then
  begin
    S1 := PPixelYC(S);
    //for Y := YHB * 2 to H - 1 do
    //begin
    for X := 0 to YWB - 1 do
    begin
      DUV^.U := (((EnsureRange(S1^.Cb, -2048, 2048) + 2048) * 7 + 66) shr 7) + 16;
      DUV^.V := (((EnsureRange(S1^.Cr, -2048, 2048) + 2048) * 7 + 66) shr 7) + 16;
      (DY1 + 0)^ := ((EnsureRange((S1 + 0)^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      (DY1 + 1)^ := ((EnsureRange((S1 + 1)^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      Inc(DY1, 2);
      Inc(S1, 2);
      Inc(DUV);
    end;
    if YWB <> UVW then
    begin
      DUV^.U := (((EnsureRange(S1^.Cb, -2048, 2048) + 2048) * 7 + 66) shr 7) + 16;
      DUV^.V := (((EnsureRange(S1^.Cr, -2048, 2048) + 2048) * 7 + 66) shr 7) + 16;
      //for X := YWB * 2 to W - 1 do
      //begin
      DY1^ := ((EnsureRange(S1^.Y, 0, 4096) * 219 + 383) shr 12) + 16;
      //Inc(DY1);
      //Inc(S1);
      //end;
      //Inc(DUV);
    end;
    //Inc(S, SLine);
    //end;
  end;
end;

function EncodeYC48ToNV12(const Parallel: TParallel; const Dest: Pointer;
  const Src: Pointer; const W, H: integer; const SLine: integer): integer; inline;
var
  Params: TEncodeYC48ToNV12Params;
begin
  Params.Dest := Dest;
  Params.Src := Src;
  Params.W := W;
  Params.H := H;
  Params.SLine := SLine;
  Parallel.Execute(@EncodeYC48ToNV12Inner, @Params, 0, H div 2);
  Result := W * H + ((W + 2 - 1) div 2) * ((H + 2 - 1) div 2) * SizeOf(TUV);
end;

type
  TDecodeNV12ToYC48Params = record
    Dest, Src: Pointer;
    W, H: integer;
    DLine: integer;
  end;
  PDecodeNV12ToYC48Params = ^TDecodeNV12ToYC48Params;

procedure DecodeNV12ToYC48Inner(const Index, N: integer; const UserData: Pointer);
var
  Params: PDecodeNV12ToYC48Params absolute UserData;
  DLine, SLine, X, Y, Cb, Cr, YWB, YHB, UVW, UVH: integer;
  D1, D2: PPixelYC;
  D, SY1, SY2: PByte;
  SUV: PUV;
begin
  YWB := Params^.W div 2;
  YHB := Params^.H div 2;
  UVW := (Params^.W + 2 - 1) div 2;
  UVH := (Params^.H + 2 - 1) div 2;

  DLine := Params^.DLine;
  D := Params^.Dest + Index * DLine * 2;
  SLine := Params^.W;
  SY1 := Params^.Src + Index * SLine * 2;
  SY2 := SY1 + SLine;
  SUV := PUV(Params^.Src + Params^.W * Params^.H) + Index * UVW;
  for Y := 0 to N - 1 do
  begin
    D1 := PPixelYC(D);
    D2 := PPixelYC(D + DLine);
    for X := 0 to YWB - 1 do
    begin
      // TODO: interpolate Cb/Cr
      Cb := ((SUV^.U - 128) * 4681 + 164) shr 8;
      Cr := ((SUV^.V - 128) * 4681 + 164) shr 8;
      (D1 + 0)^.Y := (((SY1 + 0)^ * 1197) shr 6) - 299;
      (D1 + 0)^.Cb := Cb;
      (D1 + 0)^.Cr := Cr;
      (D1 + 1)^.Y := (((SY1 + 1)^ * 1197) shr 6) - 299;
      (D1 + 1)^.Cb := Cb;
      (D1 + 1)^.Cr := Cr;
      (D2 + 0)^.Y := (((SY2 + 0)^ * 1197) shr 6) - 299;
      (D2 + 0)^.Cb := Cb;
      (D2 + 0)^.Cr := Cr;
      (D2 + 1)^.Y := (((SY2 + 1)^ * 1197) shr 6) - 299;
      (D2 + 1)^.Cb := Cb;
      (D2 + 1)^.Cr := Cr;
      Inc(SY1, 2);
      Inc(SY2, 2);
      Inc(D1, 2);
      Inc(D2, 2);
      Inc(SUV);
    end;
    if YWB <> UVW then
    begin
      Cb := ((SUV^.U - 128) * 4681 + 164) shr 8;
      Cr := ((SUV^.V - 128) * 4681 + 164) shr 8;
      //for X := YWB * 2 to W - 1 do
      //begin
      D1^.Y := ((SY1^ * 1197) shr 6) - 299;
      D1^.Cb := Cb;
      D1^.Cr := Cr;
      D2^.Y := ((SY2^ * 1197) shr 6) - 299;
      D2^.Cb := Cb;
      D2^.Cr := Cr;
      Inc(SY1);
      Inc(SY2);
      Inc(D1);
      Inc(D2);
      //end;
      Inc(SUV);
    end;
    Inc(D, DLine * 2);
    Inc(SY1, SLine);
    Inc(SY2, SLine);
  end;
  if (Index + N = YHB) and (YHB <> UVH) then
  begin
    D1 := PPixelYC(D);
    //for Y := YHB * 2 to H - 1 do
    //begin
    for X := 0 to YWB - 1 do
    begin
      // TODO: interpolate Cb/Cr
      Cb := ((SUV^.U - 128) * 4681 + 164) shr 8;
      Cr := ((SUV^.V - 128) * 4681 + 164) shr 8;
      (D1 + 0)^.Y := (((SY1 + 0)^ * 1197) shr 6) - 299;
      (D1 + 0)^.Cb := Cb;
      (D1 + 0)^.Cr := Cr;
      (D1 + 1)^.Y := (((SY1 + 1)^ * 1197) shr 6) - 299;
      (D1 + 1)^.Cb := Cb;
      (D1 + 1)^.Cr := Cr;
      Inc(SY1, 2);
      Inc(D1, 2);
      Inc(SUV);
    end;
    if YWB <> UVW then
    begin
      Cb := ((SUV^.U - 128) * 4681 + 164) shr 8;
      Cr := ((SUV^.V - 128) * 4681 + 164) shr 8;
      //for X := YWB * 2 to W - 1 do
      //begin
      D1^.Y := ((SY1^ * 1197) shr 6) - 299;
      D1^.Cb := Cb;
      D1^.Cr := Cr;
      //Inc(SY1);
      //Inc(D1);
      //end;
      //Inc(SUV);
    end;
    //Inc(D, DLine);
    //end;
  end;
end;

procedure DecodeNV12ToYC48(const Parallel: TParallel; const Dest: Pointer;
  const Src: Pointer; const W, H: integer; const DLine: integer); inline;
var
  Params: TDecodeNV12ToYC48Params;
begin
  Params.Dest := Dest;
  Params.Src := Src;
  Params.W := W;
  Params.H := H;
  Params.DLine := DLine;
  Parallel.Execute(@DecodeNV12ToYC48Inner, @Params, 0, H div 2);
end;

end.
