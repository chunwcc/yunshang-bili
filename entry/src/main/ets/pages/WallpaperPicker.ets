// WallpaperPicker.ets - 从相册选取图片并保存到应用沙箱
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

export namespace WallpaperPicker {
  export type WallpaperChangeCallback = (uri: string) => void;

  export async function pickAndSetWallpaper(context: common.Context, onSuccess: WallpaperChangeCallback): Promise<void> {
    try {
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;

      const photoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const photoSelectResult: photoAccessHelper.PhotoSelectResult = await photoViewPicker.select(photoSelectOptions);

      if (photoSelectResult.photoUris.length === 0) {
        logInfo("未选择图片");
        return;
      }

      const sourceUri = photoSelectResult.photoUris[0];
      const destUri = await copyImageToCache(context, sourceUri);
      if (destUri) {
        onSuccess(destUri);
      }
    } catch (error) {
      const err = error as BusinessError;
      logError(`选择壁纸失败: ${err.code} - ${err.message}`);
    }
  }

  async function copyImageToCache(context: common.Context, sourceUri: string): Promise<string | null> {
    const cacheDir = context.cacheDir;
    const fileName = `wallpaper_${Date.now()}.jpg`;
    const destUri = `${cacheDir}/${fileName}`;

    try {
      const srcFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const destFile = fileIo.openSync(destUri, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);

      const buffer = new ArrayBuffer(4096);
      let readLen = 0;
      while ((readLen = fileIo.readSync(srcFile.fd, buffer)) > 0) {
        fileIo.writeSync(destFile.fd, buffer.slice(0, readLen));
      }

      fileIo.closeSync(srcFile.fd);
      fileIo.closeSync(destFile.fd);
      logInfo(`壁纸已保存: ${destUri}`);
      return destUri;
    } catch (error) {
      logError(`复制图片失败: ${JSON.stringify(error)}`);
      return null;
    }
  }
}