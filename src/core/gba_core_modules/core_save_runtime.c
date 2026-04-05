// Imported from reference implementation: zip.c


#include "../common.h"
#ifdef HAVE_ZLIB
#include <zlib.h>
#endif

#define ZIP_BUFFER_SIZE (128 * 1024)

struct SZIPFileDataDescriptor
{
  s32 CRC32;
  s32 CompressedSize;
  s32 UncompressedSize;
} __attribute__((packed));

struct SZIPFileHeader
{
  char Sig[4]; // EDIT: Used to be s32 Sig;
  s16 VersionToExtract;
  s16 GeneralBitFlag;
  s16 CompressionMethod;
  s16 LastModFileTime;
  s16 LastModFileDate;
  struct SZIPFileDataDescriptor DataDescriptor;
  s16 FilenameLength;
  s16 ExtraFieldLength;
}  __attribute__((packed));

u32 load_file_zip(char *filename)
{
  struct SZIPFileHeader data;
  char tmp[1024];
  s32 retval = -1;
  u8 *buffer = NULL;
  u8 *cbuffer;
  char *ext;
  int ret;

  file_open(fd, filename, read);

  if(!file_check_valid(fd))
    return -1;

  while (1)
  {
    ret = file_read(fd, &data, sizeof(data));
    if (ret != sizeof(data))
      break;

    // It checks for the following: 0x50 0x4B 0x03 0x04 (PK..)
    if( data.Sig[0] != 0x50 || data.Sig[1] != 0x4B ||
        data.Sig[2] != 0x03 || data.Sig[3] != 0x04 )
    {
      break;
    }

    ret = file_read(fd, tmp, data.FilenameLength);
    if (ret != data.FilenameLength)
      break;

    tmp[data.FilenameLength] = 0; // end string

    if(data.ExtraFieldLength)
      file_seek(fd, data.ExtraFieldLength, SEEK_CUR);

    if(data.GeneralBitFlag & 0x0008)
    {
      file_read(fd, &data.DataDescriptor,
       sizeof(struct SZIPFileDataDescriptor));
    }

    ext = strrchr(tmp, '.') + 1;

    // file is too big
    if(data.DataDescriptor.UncompressedSize > gamepak_ram_buffer_size)
      goto skip;

    if(!strcasecmp(ext, "bin") || !strcasecmp(ext, "gba"))
    {
      buffer = gamepak_rom;

      // ok, found
      switch(data.CompressionMethod)
      {
        case 0:
          retval = data.DataDescriptor.UncompressedSize;
          file_read(fd, buffer, retval);
          goto outcode;

        case 8:
#ifdef HAVE_ZLIB
        {
          z_stream stream;
          s32 err;

          cbuffer = malloc(ZIP_BUFFER_SIZE);

          stream.next_in = (Bytef*)cbuffer;
          stream.avail_in = (u32)ZIP_BUFFER_SIZE;

          stream.next_out = (Bytef*)buffer;

          // EDIT: Now uses proper conversion of data types for retval.
          retval = (u32)data.DataDescriptor.UncompressedSize;
          stream.avail_out = data.DataDescriptor.UncompressedSize;

          stream.zalloc = (alloc_func)0;
          stream.zfree = (free_func)0;

          err = inflateInit2(&stream, -MAX_WBITS);

          file_read(fd, cbuffer, ZIP_BUFFER_SIZE);

          if(err == Z_OK)
          {
            while(err != Z_STREAM_END)
            {
              err = inflate(&stream, Z_SYNC_FLUSH);
              if(err == Z_BUF_ERROR)
              {
                stream.avail_in = ZIP_BUFFER_SIZE;
                stream.next_in = (Bytef*)cbuffer;
                file_read(fd, cbuffer, ZIP_BUFFER_SIZE);
              }
            }
            err = Z_OK;
            inflateEnd(&stream);
          }
          free(cbuffer);
          goto outcode;
        }
#else
          // Deflate-compressed zip entries require zlib support.
          goto skip;
#endif
      }
    }

skip:
    file_seek(fd, data.DataDescriptor.CompressedSize, SEEK_CUR);
  }

outcode:
  file_close(fd);

  return retval;
}
